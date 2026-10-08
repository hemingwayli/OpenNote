"""生成界面回归专用的自产阅读样例；不引用外部文章或分发字体文件。"""
from pathlib import Path
import pymupdf as fitz

output = Path(__file__).resolve().parent / 'pdf' / 'ui-reading.pdf'
doc = fitz.open()
ink = (.15, .18, .22)
muted = (.40, .44, .49)
blue = (.21, .45, .76)
for index in range(2):
    page = doc.new_page(width=600, height=800)
    page.insert_text((60, 54), 'OPENNOTE   /   READING NOTES', fontsize=9, color=muted)
    page.draw_line((60, 70), (540, 70), color=(.86, .88, .91), width=.6)
    page.insert_text((60, 125), 'Reading for understanding' if index == 0 else 'Connect ideas. Build perspective.', fontsize=26, fontname='hebo', color=ink)
    page.insert_text((60, 153), 'A practical guide to thoughtful, connected reading', fontsize=11, color=muted)
    page.insert_text((60, 197), '01   FROM INFORMATION TO INSIGHT' if index == 0 else '02   A PERSONAL KNOWLEDGE PRACTICE', fontsize=10, fontname='hebo', color=blue)
    paragraphs = [
      'Reading is more than collecting sentences. Understanding begins when we pause, identify the central idea, and describe it in our own words. A useful note makes that change in perspective visible.',
      'Keep the source and your interpretation close, but give each its own place. An excerpt preserves what the author wrote. A personal note records what you think, question, or want to try next.',
      'Connections turn individual observations into a useful structure. Compare two ideas, name the relationship, and return to the original context whenever a detail needs to be checked.',
    ]
    y=222
    for paragraph in paragraphs:
        page.insert_textbox(fitz.Rect(60,y,540,y+100),paragraph,fontname='helv',fontsize=12,lineheight=1.65,color=ink)
        y+=103
    page.draw_rect(fitz.Rect(60,537,540,610),color=None,fill=(.95,.97,.99))
    page.draw_line((60,537),(60,610),color=blue,width=2)
    page.insert_text((78,561),'A small practice',fontname='hebo',fontsize=11,color=blue)
    page.insert_textbox(fitz.Rect(78,574,520,609),'Read one section. Write one clear idea. Connect it to something you already know.',fontname='helv',fontsize=12,lineheight=1.5,color=ink)
    page.insert_text((60,657),'A quieter workspace supports deeper attention.',fontname='hebo',fontsize=14,color=ink)
    page.insert_textbox(fitz.Rect(60,674,535,734),'Keep the document in view, give your notes a clear hierarchy, and let tools stay within reach without competing with the content.',fontname='helv',fontsize=12,lineheight=1.65,color=muted)
    page.draw_line((60,755),(540,755),color=(.86,.88,.91),width=.6)
    page.insert_text((60,775),'OpenNote / Original UI verification fixture',fontsize=8,color=muted)
    page.insert_text((530,775),str(index+1),fontsize=9,color=muted)
doc.set_metadata({'title':'Reading for understanding','author':'OpenNote','creationDate':'D:20261004000000Z','modDate':'D:20261004000000Z'})
doc.save(output, deflate=True, no_new_id=True)
doc.close()
print(output)
