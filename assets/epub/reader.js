/* OpenNote 本地阅读桥接；书籍自身脚本始终禁用，来源使用 CFI 而非重排页码。 */
(() => {
  'use strict';
  let config, book, rendition, generation = 0, destroyed = false;
  let currentSelection = null, indexCancelled = false;
  const indexedDone = new Set();
  let indexSequence = 0;
  let appliedSize='';
  const normalize = s => String(s || '').replace(/\s+/g, ' ').trim();
  function send(type, payload = {}) {
    if (destroyed || !config || !window.flutter_inappwebview) return;
    return window.flutter_inappwebview.callHandler('opennote', {
      session: config.session, revision: config.revision, generation: config.generation,
      type, ...payload,
    });
  }
  function hrefOf(section) {
    const url = new URL(section.href, config.opf);
    return decodeURIComponent(url.pathname.split('/book/')[1]);
  }
  function locator(section, range, imageHref, element) {
    if(element) {
      const point=range.startContainer.ownerDocument.createRange();point.setStart(element,0);point.collapse(true);range=point;
    }
    const cfi = element ? section.cfiFromElement(element) : section.cfiFromRange(range);
    const quote = range.toString();
    const before=range.cloneRange(), after=range.cloneRange();
    // CFI 还原可以采用不同的 DOM 边界节点；上下文统一相对整章正文计算。
    const document=range.startContainer.ownerDocument || section.document;
    const root=document.body || document.documentElement;
    before.selectNodeContents(root);before.setEnd(range.startContainer,range.startOffset);
    after.selectNodeContents(root);after.setStart(range.endContainer,range.endOffset);
    return {version:1, format:'epub', href:hrefOf(section), cfi,
      quote, prefix:before.toString().slice(-32), suffix:after.toString().slice(0,32), imageHref:imageHref || null, crop:[]};
  }
  function style(contents) {
    const document = contents.document;
    const policy = document.createElementNS('http://www.w3.org/1999/xhtml','meta');
    policy.httpEquiv = 'Content-Security-Policy';
    policy.content = "default-src 'none'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'none'; media-src 'none'; object-src 'none'; base-uri 'self'";
    const head=document.head || document.documentElement;
    head.prepend(policy);
    const sheet = document.createElementNS(document.documentElement.namespaceURI==='http://www.w3.org/2000/svg'?'http://www.w3.org/2000/svg':'http://www.w3.org/1999/xhtml','style');
    sheet.dataset.opennote = 'style';
    sheet.textContent = `@font-face{font-family:'Source Han Sans CN';font-display:swap;src:url('${config.fontUrl}')} html{color:#262b33} ::selection{background:#3574cb33}`;
    head.appendChild(sheet);
    const section = book.spine.get(contents.sectionIndex);
    const fixed = config.sections[contents.sectionIndex]?.fixedLayout;
    if (!fixed) {
      // 可重排书的原图按当前正文宽度收缩；固定版式保留作者尺寸。
      sheet.textContent += 'img,svg{max-width:100% !important;height:auto}';
      contents.css('font-size', config.settings.fontSize + 'px', true);
      contents.css('line-height', String(config.settings.lineHeight), true);
      contents.css('font-family', config.settings.font, true);
      contents.css('padding', config.settings.margin + 'px', true);
      contents.css('box-sizing', 'border-box', true);
    }
    document.addEventListener('mouseup', () => {
      const selected = contents.window.getSelection();
      if (!selected || selected.isCollapsed || !selected.rangeCount) return;
      const range = selected.getRangeAt(0);
      const anchor = locator(section, range);
      currentSelection = {text:range.toString(), anchors:[anchor]};
      send('selection', currentSelection);
    });
    document.addEventListener('contextmenu', event => {
      event.preventDefault();
      const image = event.target.closest?.('img,svg');
      if (!image) return;
      const range = document.createRange();
      range.selectNode(image);
      let imageHref = null;
      if (image.tagName.toLowerCase() === 'img' && image.src && !image.src.startsWith('data:')) {
        const url = new URL(image.getAttribute('src'), new URL(section.href, config.opf));
        imageHref = decodeURIComponent(url.pathname.split('/book/')[1] || '');
      }
      const anchor = locator(section, range, imageHref,image);
      anchor.crop=[0,0,1,1];
      const box = image.getBoundingClientRect();
      const view = rendition.manager.views.find(section);
      const frameBox = view?.iframe?.getBoundingClientRect();
      currentSelection = {text:image.getAttribute('alt') || '', anchors:[anchor], imageHref,
        rect: frameBox ? {x:frameBox.x + box.x, y:frameBox.y + box.y, width:box.width, height:box.height} : null};
      send('selection', currentSelection);
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape') send('escape');
      if (event.ctrlKey && event.key.toLowerCase() === 'f') {event.preventDefault();send('search');}
    });
  }
  async function initialize(input) {
    config = input;
    destroyed = false;
    book = ePub(config.opf);
    await book.ready;
    // 使用 XHTML/XML 原始 DOM 渲染，表格等结构不会被 HTML 自动补节点破坏 CFI。
    book.spine.hooks.content.register((document,section)=>{
      const url=new URL(section.href,config.opf).href;
      if(document.head) {
        for(const old of document.head.querySelectorAll('base')) old.remove();
        const base=document.createElementNS('http://www.w3.org/1999/xhtml','base');
        base.setAttribute('href',url);document.head.prepend(base);
      } else document.documentElement.setAttributeNS('http://www.w3.org/XML/1998/namespace','xml:base',url);
    });
    rendition = book.renderTo('reader', {
      width:'100%', height:'100%', flow: config.settings.paginated ? 'paginated' : 'scrolled-doc',
      spread:'none', allowScriptedContent:false,
      method:'blobUrl',
    });
    rendition.hooks.content.register(style);
    rendition.on('relocated', location => {
      const section = book.spine.get(location.start.index);
      send('position', {locator:{version:1,format:'epub',href:hrefOf(section),cfi:location.start.cfi,
        quote:'',prefix:'',suffix:'',imageHref:null,crop:[]}, index:section.index,
        progress:(section.index + (location.start.displayed.page / Math.max(1,location.start.displayed.total))) / book.spine.length});
    });
    rendition.on('markClicked', (cfi, data) => send('annotation', {id:data.id}));
    rendition.on('rendered',section=>{
      const fixed=config.sections[section.index]?.fixedLayout;
      applyZoom(fixed?config.settings.fixedZoom || 1:1,fixed).catch(error=>send('error',{message:error.message}));
      for(const contents of rendition.getContents()) renderMedia(contents);
    });
    rendition.on('resized',()=>{for(const contents of rendition.getContents()) renderMedia(contents);});
    await rendition.display(config.position?.cfi || undefined);
    await painted();
    send('ready', {sections:config.sections.length});
    return true;
  }
  async function jump(anchor, request) {
    const mine = ++generation;
    const section = book.spine.get(anchor.cfi);
    if (!section || hrefOf(section) !== anchor.href) throw Error('来源章节与 CFI 不一致');
    await section.load(book.load.bind(book));
    const range = await book.getRange(anchor.cfi);
    if (anchor.quote && normalize(range.toString()) !== normalize(anchor.quote)) throw Error('来源文字校验不一致，保留原摘录');
    const checked=locator(section,range,anchor.imageHref);
    // 上下文可能短于 32 字符（靠近章节边界或旧搜索结果），仍须逐字匹配。
    if((anchor.prefix && !checked.prefix.endsWith(anchor.prefix)) || (anchor.suffix && !checked.suffix.startsWith(anchor.suffix))) throw Error('来源上下文校验不一致，保留原摘录');
    if(anchor.imageHref) {
      const candidate=range.cloneContents().querySelector?.('img') ||
        (range.startContainer.nodeType===Node.ELEMENT_NODE && range.startContainer.matches('img') ? range.startContainer : null);
      if(!candidate) throw Error('来源图片元素无法定位');
      const path=decodeURIComponent(new URL(candidate.getAttribute('src'),new URL(section.href,config.opf)).pathname.split('/book/')[1] || '');
      if(path!==anchor.imageHref) throw Error('来源图片校验不一致，保留原摘录');
    }
    if (mine !== generation || destroyed) return false;
    await rendition.display(anchor.cfi);
    await painted();
    if (mine !== generation || destroyed) return false;
    // 临时回源使用独立标记类型，避免移除同范围的持久高亮。
    if(anchor.imageHref || anchor.crop?.length) {
      const contents=rendition.getContents().find(c=>c.sectionIndex===section.index);
      const element=mediaElement(contents,anchor);
      if(!element) throw Error('来源图片无法在当前排版中定位');
      element.scrollIntoView({block:'center',inline:'nearest'});
      mediaOverlay(contents,anchor,'#3574cb',null,true);
      return {request,success:true};
    }
    rendition.annotations.underline(anchor.cfi, {temporary:true}, null, 'source-emphasis', {stroke:'#3574cb','stroke-width':'2'});
    setTimeout(() => { if (!destroyed) rendition.annotations.remove(anchor.cfi,'underline'); }, 1500);
    return {request, success:true};
  }
  async function settings(value) {
    const position = rendition.currentLocation()?.start?.cfi;
    config.settings = value;
    rendition.flow(value.paginated ? 'paginated' : 'scrolled-doc');
    for (const contents of rendition.getContents()) {
      const fixed = config.sections[contents.sectionIndex]?.fixedLayout;
      if (fixed) continue;
      contents.css('font-size', value.fontSize + 'px', true);
      contents.css('line-height', String(value.lineHeight), true);
      contents.css('font-family', value.font, true);
      contents.css('padding', value.margin + 'px', true);
    }
    await rendition.resize();
    if (position) await rendition.display(position);
    await painted();
    for(const contents of rendition.getContents()) renderMedia(contents);
  }
  async function painted() {
    for (const contents of rendition.getContents()) await contents.document.fonts.ready;
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
  }
  async function applyZoom(scale,fixed) {
    const target=document.getElementById('reader');
    const width=fixed?Math.round(window.innerWidth*scale):window.innerWidth;
    const height=fixed?Math.round(window.innerHeight*scale):window.innerHeight;
    const key=[width,height,!!fixed].join(':');if(key===appliedSize) return true;
    const firstLayout=!appliedSize;
    const activeIndex=rendition.getContents()[0]?.sectionIndex ?? 0;
    const location=rendition.currentLocation()?.start;
    const targetLocation=location?.index===activeIndex?location.cfi:book.spine.get(activeIndex).href;
    appliedSize=key;
    document.documentElement.style.overflow=fixed?'auto':'hidden';
    document.body.style.overflow=fixed?'visible':'hidden';
    target.style.width=fixed?width+'px':'100%';target.style.height=fixed?height+'px':'100%';
    if(!(firstLayout && scale===1)) {
      await rendition.resize(width,height);
      // epub.js 的 resize 会异步重建视图；等待 display 回执再读取新 DOM。
      await rendition.display(targetLocation);
    }
    await painted();return true;
  }
  async function zoom(scale) {
    config.settings.fixedZoom=scale;
    const index=rendition.currentLocation()?.start?.index ?? 0;
    return applyZoom(scale,config.sections[index]?.fixedLayout);
  }
  window.addEventListener('resize',()=>{
    if(!rendition || destroyed) return;
    const index=rendition.currentLocation()?.start?.index ?? 0;
    const fixed=config.sections[index]?.fixedLayout;
    applyZoom(fixed?config.settings.fixedZoom || 1:1,fixed).catch(error=>send('error',{message:error.message}));
  });
  async function indexSection(index) {
    const section = book.spine.get(index);
    await section.load(book.load.bind(book));
    const document = section.document;
    const root = document.body || document.documentElement;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {return node.parentElement?.closest('script,style,head') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;}
    });
    let text = '', node;
    const fragments = [];
    while ((node = walker.nextNode())) {
      if (!node.textContent.length) continue;
      const range = document.createRange();range.setStart(node,0);range.collapse(true);
      fragments.push({start:text.length,length:node.textContent.length,cfi:section.cfiFromRange(range)});
      text += node.textContent;
    }
    return {href:hrefOf(section), index, text, fragments};
  }
  async function indexAll(completed, priority) {
    const sequence=++indexSequence;
    indexCancelled = false;
    const missing = new Set([...(completed || []),...indexedDone]);
    const order = [priority, ...config.sections.map(s=>s.index)].filter((v,i,a)=>v>=0 && a.indexOf(v)===i);
    for (const index of order) {
      if (indexCancelled || destroyed || sequence!==indexSequence) break;
      if (missing.has(index)) continue;
      const data = await indexSection(index);
      if (indexCancelled || destroyed || sequence!==indexSequence) break;
      await send('index', data);
      indexedDone.add(index);
      await new Promise(resolve => setTimeout(resolve,0));
    }
    if (!indexCancelled && !destroyed && sequence===indexSequence) send('indexed');
  }
  function annotations(items) {
    if (!rendition) return;
    for (const old of (config.annotationCfis || [])) rendition.annotations.remove(old, 'highlight');
    config.annotationCfis = [];
    config.annotationItems=items;
    for (const item of items) {
      if (!item.locator?.cfi) continue;
      if(item.locator.imageHref || item.locator.crop?.length) continue;
      rendition.annotations.highlight(item.locator.cfi, {id:item.id}, null, 'persistent-annotation',
        {fill:item.color,'fill-opacity':'0.25'});
      config.annotationCfis.push(item.locator.cfi);
    }
    for(const contents of rendition.getContents()) renderMedia(contents);
  }
  function mediaElement(contents,anchor) {
    if(!contents) return null;
    const range=contents.range(anchor.cfi);
    const element=range.startContainer.nodeType===Node.ELEMENT_NODE?range.startContainer:range.startContainer.parentElement;
    return element?.matches('img,svg')?element:element?.closest('img,svg');
  }
  function mediaOverlay(contents,anchor,color,id,temporary=false) {
    const element=mediaElement(contents,anchor);if(!element) return;
    const document=contents.document,box=element.getBoundingClientRect();
    const crop=anchor.crop?.length?anchor.crop:[0,0,1,1];
    const mark=document.createElementNS('http://www.w3.org/1999/xhtml','div');mark.dataset.opennoteMedia=temporary?'temporary':'annotation';
    Object.assign(mark.style,{position:'absolute',left:(box.x+contents.window.scrollX+crop[0]*box.width)+'px',
      top:(box.y+contents.window.scrollY+crop[1]*box.height)+'px',width:(crop[2]*box.width)+'px',height:(crop[3]*box.height)+'px',
      boxSizing:'border-box',border:'2px solid '+color,background:color+'22',zIndex:'2147483646',pointerEvents:temporary?'none':'auto'});
    if(id) {
      mark.addEventListener('click',event=>{event.stopPropagation();send('annotation',{id});});
      mark.addEventListener('contextmenu',event=>{event.preventDefault();event.stopPropagation();element.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));});
    }
    document.documentElement.appendChild(mark);
    if(temporary) setTimeout(()=>mark.remove(),1500);
  }
  function renderMedia(contents) {
    if(destroyed || !contents?.document) return;
    for(const mark of contents.document.querySelectorAll('[data-opennote-media="annotation"]')) mark.remove();
    for(const item of config.annotationItems || []) {
      const section=book.spine.get(item.locator?.cfi);
      if(section?.index!==contents.sectionIndex || !(item.locator.imageHref || item.locator.crop?.length)) continue;
      mediaOverlay(contents,item.locator,item.color,item.id);
    }
  }
  function region(rect) {
    const anchors = [];
    for (const contents of rendition.getContents()) {
      const section = book.spine.get(contents.sectionIndex);
      const view = rendition.manager.views.find(section);
      const box = view?.iframe?.getBoundingClientRect();
      if (!box || rect.x > box.right || rect.y > box.bottom || rect.x+rect.width < box.left || rect.y+rect.height < box.top) continue;
      const document = contents.document;
      for (const image of document.querySelectorAll('img,svg')) {
        const imageBox=image.getBoundingClientRect();
        const left=Math.max(rect.x-box.x,imageBox.left),top=Math.max(rect.y-box.y,imageBox.top);
        const right=Math.min(rect.x+rect.width-box.x,imageBox.right),bottom=Math.min(rect.y+rect.height-box.y,imageBox.bottom);
        if(right<=left || bottom<=top || !imageBox.width || !imageBox.height) continue;
        const range=document.createRange();range.selectNode(image);
        let imageHref=null;
        if(image.tagName.toLowerCase()==='img' && image.getAttribute('src') && !image.getAttribute('src').startsWith('data:')) {
          imageHref=decodeURIComponent(new URL(image.getAttribute('src'),new URL(section.href,config.opf)).pathname.split('/book/')[1] || '');
        }
        const anchor=locator(section,range,imageHref,image);
        anchor.crop=[(left-imageBox.left)/imageBox.width,(top-imageBox.top)/imageBox.height,
          (right-left)/imageBox.width,(bottom-top)/imageBox.height];
        anchors.push(anchor);
      }
      const sx = Math.max(1,rect.x-box.x), sy = Math.max(1,rect.y-box.y);
      const ex = Math.min(box.width-1,rect.x+rect.width-box.x), ey = Math.min(box.height-1,rect.y+rect.height-box.y);
      const first = document.caretRangeFromPoint(sx,sy);
      const last = document.caretRangeFromPoint(ex,ey);
      if (first && last) {
        const range = document.createRange();
        try {range.setStart(first.startContainer,first.startOffset);range.setEnd(last.startContainer,last.startOffset);}
        catch (_) {continue;}
        if(!range.collapsed && range.toString().trim()) anchors.push(locator(section,range));
      } else {
        const target = document.elementFromPoint(sx,sy) || document.body;
        const range = document.createRange();range.selectNode(target);
        anchors.push(locator(section,range));
      }
    }
    return {text:anchors.map(a=>a.quote).join('\n'),anchors};
  }
  window.openNote = {
    initialize, jump, settings, annotations, indexAll, region,
    next:()=>rendition.next(), previous:()=>rendition.prev(),
    chapter:href=>{
      const [path,fragment]=href.split('#');
      const section=config.sections.find(s=>s.href===path);
      if(!section) throw Error('目录引用的章节不存在');
      return rendition.display(book.spine.get(section.index).href+(fragment?'#'+fragment:''));
    },
    selection:()=>currentSelection,
    cancelIndex:()=>{indexCancelled=true;},
    probe: async (startIndex=0) => {
      let data, selectedIndex=0;
      const base=Math.max(0,Math.min(config.sections.length-1,Number(startIndex)||0));
      for(let offset=0;offset<Math.min(config.sections.length,16);offset++) {
        const i=(base+offset)%config.sections.length;
        data=await indexSection(i);selectedIndex=i;
        if(data.text.trim().length>=8) break;
      }
      const section = book.spine.get(selectedIndex);
      const document = section.document;
      const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
      let textNode;while((textNode=walker.nextNode()) && !textNode.textContent.trim()) {}
      if(!textNode) throw Error('探针未找到有效正文');
      const range = document.createRange();range.setStart(textNode,0);range.setEnd(textNode,Math.min(textNode.length,8));
      const anchor = locator(section,range);
      await jump(anchor,1);
      await jump({...anchor,prefix:anchor.prefix.slice(-12),suffix:anchor.suffix.slice(0,12)},101);
      let rejected=false;
      try {await jump({...anchor,suffix:'OpenNote 验证错误上下文'},102);} catch (_) {rejected=true;}
      if(!rejected) throw Error('来源上下文不一致未被拒绝');
      await settings({...config.settings,fontSize:26,lineHeight:2});
      await jump(anchor,2);
      await painted();
      const contents=rendition.getContents().find(c=>c.sectionIndex===selectedIndex);
      for(const fragment of data.fragments) {
        const original=(await book.getRange(fragment.cfi)).startContainer.textContent;
        const rendered=contents.range(fragment.cfi).startContainer.textContent;
        if(original!==rendered) throw Error('正文索引与实际渲染 DOM 的 CFI 不一致');
      }
      const images=[...contents.document.querySelectorAll('img')];
      if(images.some(image=>!image.complete || image.naturalWidth===0)) throw Error('可见章节图片未加载');
      const writingMode=contents.window.getComputedStyle(contents.document.body).writingMode;
      const originalMode=config.settings.paginated;
      await settings({...config.settings,paginated:!originalMode});
      await jump(anchor,3);
      const paginatedContents=rendition.getContents().find(c=>c.sectionIndex===selectedIndex);
      if(normalize(paginatedContents.range(anchor.cfi).toString())!==normalize(anchor.quote)) throw Error('切换分页模式后来源不一致');
      await settings({...config.settings,paginated:originalMode});
      const fixedChecks=[];
      for(const item of config.sections.filter(s=>s.fixedLayout)) {
        await rendition.display(book.spine.get(item.index).href);await painted();
        const view=rendition.getContents().find(c=>c.sectionIndex===item.index);
        const width=rendition.manager.views.find(book.spine.get(item.index)).iframe.getBoundingClientRect().width;
        await zoom(1.5);
        if(window.document.documentElement.scrollWidth<=window.innerWidth ||
          rendition.manager.views.find(book.spine.get(item.index)).iframe.getBoundingClientRect().width<=width) throw Error('固定版式缩放：scroll='+window.document.documentElement.scrollWidth+', viewport='+window.innerWidth+', before='+width+', after='+rendition.manager.views.find(book.spine.get(item.index)).iframe.getBoundingClientRect().width);
        await zoom(1);
        const current=rendition.getContents().find(c=>c.sectionIndex===item.index);
        const before=current.window.getComputedStyle(current.document.body).fontSize;
        await settings({...config.settings,fontSize:42,lineHeight:2.5});
        const after=rendition.getContents().find(c=>c.sectionIndex===item.index);
        if(after.window.getComputedStyle(after.document.body).fontSize!==before) throw Error('固定版式受到重排字号设置影响');
        fixedChecks.push(item.index);
      }
      await settings({...config.settings,fontSize:26,lineHeight:2,paginated:originalMode});
      await jump(anchor,4);
      return {index:data,anchor,text:(await book.getRange(anchor.cfi)).toString(),sampledSection:selectedIndex,
        contentType:contents.document.contentType,imageCount:images.length,
        paginationCfi:true,fixedSectionsValidated:fixedChecks,
        math:document.querySelectorAll('math').length,
        svg:document.querySelectorAll('svg').length,
        writingMode};
    },
    zoom,
    destroy:()=>{destroyed=true;indexCancelled=true;generation++;rendition?.destroy();book?.destroy();book=null;rendition=null;return true;},
  };
})();
