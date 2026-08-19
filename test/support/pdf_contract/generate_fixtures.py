from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.utils import ImageReader
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
from pypdf import PdfReader, PdfWriter

ROOT=Path(__file__).parent
fr="Conseil communal ordre du jour proposition publique decision officielle seance ouverte aux citoyens"
nl="Gemeenteraad agenda openbaar voorstel officieel besluit gemeentelijke zitting voor alle inwoners"

def pdf(name, pages):
    c=canvas.Canvas(str(ROOT/name),pagesize=A4,pageCompression=0,invariant=1)
    for page in pages:
        if page.get('rotate'): c.setPageRotation(page['rotate'])
        y=780
        for line in page.get('lines',[]):
            c.drawString(45,y,line); y-=24
        if page.get('image'):
            im=Image.new('RGB',(2400,1000),'white'); d=ImageDraw.Draw(im)
            font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',52)
            words=page['image'].split(); lines=[]; current=[]
            for word in words:
                if len(' '.join(current+[word])) > 55:
                    lines.append(' '.join(current)); current=[word]
                else: current.append(word)
            lines.append(' '.join(current))
            for idx,line in enumerate(lines): d.text((80,100+idx*100),line,font=font,fill='black')
            p=ROOT/(name.stem+'.png'); im.save(p)
            c.drawImage(ImageReader(str(p)),45,350,width=500,height=180)
            p.unlink()
        c.showPage()
    c.save()

pdf(Path('ixelles-born-digital.pdf'),[{'lines':['IXELLES / ELSENE',fr,nl]}])
pdf(Path('uccle-bilingual.pdf'),[{'lines':['UCCLE / UKKEL',fr,nl,fr,nl]}])
pdf(Path('forest-partial-scan.pdf'),[{'lines':['FOREST / VORST',fr,nl]},{'image':fr+' / '+nl}])
pdf(Path('city-unrotated.pdf'),[{'image':fr+' / '+nl}])
reader=PdfReader(str(ROOT/'city-unrotated.pdf')); writer=PdfWriter()
writer.add_page(reader.pages[0].rotate(90)); writer.write(str(ROOT/'city-rotated.pdf'))
(ROOT/'city-unrotated.pdf').unlink()

pdf(Path('scanned-bilingual.pdf'),[{'image':fr+' / '+nl}])
(ROOT/'malformed.pdf').write_bytes(b'%PDF-1.7\nnot a valid xref table\n%%EOF\n')
