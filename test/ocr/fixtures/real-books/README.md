# 真实公共领域印刷书扫描

这些 JPEG 为原始出版物的机械扫描单页缩略图下载，保留纸张、印刷、透字与瑕疵；不是重新生成的文字位图。URL、出版年份、上游公共领域声明及 SHA-256 见 `tools/ocr/real-book-samples.json`。只保存三页用于回归，完整书未下载。

- `austen-page11.jpg`：Jane Austen，Pride and Prejudice，1817 第三版，Internet Archive 扫描，Commons `PD-scan / PD-old-100-expired`。
- `chinese-page20.jpg`：趙玉森編纂，《共和國教科書本國史》，1920，商務印書館，國家圖書館扫描，Commons `PD-scan / PD-China`。
- `hillier-page110.jpg`：Sir Walter Hillier，The Chinese language and how to learn it，1921，Internet Archive 扫描，Commons `PD-old` / Public Domain Mark。
- `chinese-page20-image-only.pdf`：直接嵌入上述中文 JPEG 字节，不重新压缩、排版或添加原生文字层。用于真实扫描页的 PDF→OCR→文字层→摘录集成测试。

`tools/ocr/validate_real_books.py --prepare-fixtures` 可从哈希核验过的少量扫描图片复现资料。人工抽段 CER 和位置 spot check 见 `tools/ocr/real-book-validation.json`，不能外推为整本书、全部旧字形或复杂版面准确率。
