"""Tiny local fixtures: no downloaded corpus or optional Python packages."""
import gzip
from pathlib import Path
import struct
import sys
import tarfile
import zipfile
import io
import zlib

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
def write(name, text):
    (root / name).write_text(text)
def zipdoc(name, entries):
    with zipfile.ZipFile(root / name, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, text in entries.items():
            archive.writestr(path, text)

def chunk(name, data):
    return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',struct.pack('>IIBBBBB',24,24,8,2,0,0,0))
png += chunk(b'IDAT',zlib.compress((b'\0'+b'\x20\x60\xc0'*24)*24)) + chunk(b'IEND',b'')
(root/'picture.png').write_bytes(png)
svg = '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect width="240" height="120" fill="#2060c0"/></svg>'
write('drawing.svg',svg)
(root/'drawing.svgz').write_bytes(gzip.compress(svg.encode()))
write('notes.txt','Shenzhen format fixture\nThis is readable text.\n')
html = '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body><h1>Format fixture</h1><p>Readable document text.</p></body></html>'
for ext in ['html','htm','xhtml']:
    write('page.'+ext,html)
write('book.fb2','<?xml version="1.0"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Fixture</book-title><lang>en</lang></title-info></description><body><section><title><p>Fixture</p></title><p>Readable book text.</p></section></body></FictionBook>')
zipdoc('book.epub',{'mimetype':'application/epub+zip','META-INF/container.xml':'<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', 'book.opf':'<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture</dc:title><dc:identifier id="id">fixture</dc:identifier><dc:language>en</dc:language></metadata><manifest><item id="p" href="page.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="p"/></spine></package>', 'page.xhtml':html})
# Uncompressed PalmDOC/MOBI, one HTML record.
text=html.encode()
header=bytearray(78); header[60:68]=b'BOOKMOBI'; header[76:78]=struct.pack('>H',2)
record=struct.pack('>HHIHHHH',1,0,len(text),1,4096,0,0)
(root/'book.mobi').write_bytes(header+struct.pack('>IIII',94,0,110,1)+record+text)
for ext in ['cbz','zip']:
    zipdoc('comic.'+ext,{'page.png':png})
for ext in ['cbt','tar']:
    with tarfile.open(root/('comic.'+ext),'w') as archive:
        info=tarfile.TarInfo('page.png'); info.size=len(png); archive.addfile(info,io.BytesIO(png))
reltype='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument'
rels='<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="'+reltype+'" Target="word/document.xml"/></Relationships>'
zipdoc('word.docx',{'_rels/.rels':rels, 'word/_rels/document.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>', 'word/document.xml':'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Readable Word fixture</w:t></w:r></w:p></w:body></w:document>'})
ns='http://schemas.microsoft.com/xps/2005/06'
xps={'_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r" Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="FixedDocSeq.fdseq"/></Relationships>', 'FixedDocSeq.fdseq':f'<FixedDocumentSequence xmlns="{ns}"><DocumentReference Source="doc.fdoc"/></FixedDocumentSequence>', 'doc.fdoc':f'<FixedDocument xmlns="{ns}"><PageContent Source="page.fpage" Width="240" Height="120"/></FixedDocument>', 'page.fpage':f'<FixedPage xmlns="{ns}" Width="240" Height="120"><Path Fill="#2060C0" Data="M 0,0 L 240,0 240,120 0,120 Z"/></FixedPage>'}
zipdoc('fixed.xps',xps)
zipdoc('fixed.oxps',{k:v.replace(ns,'http://schemas.openxps.org/oxps/v1.0') for k,v in xps.items()})
relsns='http://schemas.openxmlformats.org/package/2006/relationships'
xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def relationship(target):
    return f'<Relationships xmlns="{relsns}"><Relationship Id="rId1" Type="{reltype}" Target="{target}"/></Relationships>'
zipdoc('sheet.xlsx',{'_rels/.rels':relationship('xl/workbook.xml'),
    'xl/workbook.xml':f'<workbook xmlns="{xmlns}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':relationship('worksheets/sheet1.xml'),
    'xl/worksheets/sheet1.xml':f'<worksheet xmlns="{xmlns}"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Readable spreadsheet</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>'})
zipdoc('slides.pptx',{'_rels/.rels':relationship('ppt/presentation.xml'),
    'ppt/presentation.xml':'<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst></p:presentation>',
    'ppt/_rels/presentation.xml.rels':relationship('slides/slide1.xml'),
    'ppt/slides/slide1.xml':'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Readable presentation</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'})
zipdoc('text.hwpx',{'META-INF/container.xml':'<container><rootfiles><rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/></rootfiles></container>',
    'Contents/content.hpf':'<package><manifest><item id="sec0" href="Contents/section0.xml" media-type="application/xml"/></manifest><spine><itemref idref="sec0"/></spine></package>',
    'Contents/section0.xml':'<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p><hp:run><hp:t>Readable HWPX document</hp:t></hp:run></hp:p></hs:sec>'})
# Netpbm and Photoshop are useful image families not covered by AppKit's encoders.
for ext, data in {'ppm':b'P6\n24 24\n255\n'+b'\x20\x60\xc0'*576,
                  'pgm':b'P5\n24 24\n255\n'+b'\x60'*576,
                  'pbm':b'P4\n24 24\n'+b'\xaa'*72,
                  'pam':b'P7\nWIDTH 24\nHEIGHT 24\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB\nENDHDR\n'+b'\x20\x60\xc0'*576,
                  'pfm':b'PF\n24 24\n-1.0\n'+struct.pack('<fff',.1,.3,.8)*576}.items():
    (root/('picture.'+ext)).write_bytes(data)
psd=b'8BPS'+struct.pack('>H',1)+bytes(6)+struct.pack('>HIIHH',3,24,24,8,3)+bytes(12)+bytes(2)
(root/'picture.psd').write_bytes(psd+b'\x20'*576+b'\x60'*576+b'\xc0'*576)
