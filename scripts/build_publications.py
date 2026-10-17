#!/usr/bin/env python3
"""Build the versioned SupaDAO DEX PDF publication set from Markdown sources."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.platypus import (
    BaseDocTemplate, Frame, PageTemplate, Paragraph, Spacer, PageBreak,
    KeepTogether, Table, TableStyle, Preformatted, Flowable
)

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
MIRROR = ROOT / "output" / "pdf"
LANDING = ROOT.parent / "landing" / "public" / "documents"

BG = colors.HexColor("#08090B")
SURFACE = colors.HexColor("#111827")
INK = colors.HexColor("#E8EEF6")
MUTED = colors.HexColor("#94A3B8")
ACCENT = colors.HexColor("#38BDF8")
LINE = colors.HexColor("#263244")
WARN = colors.HexColor("#F59E0B")

FONT = "Helvetica"
FONT_BOLD = "Helvetica-Bold"
MONO = "Courier"
for regular, bold, mono in [
    ("/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Supplemental/Courier New.ttf"),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
]:
    if Path(regular).exists() and Path(bold).exists():
        pdfmetrics.registerFont(TTFont("SupaSans", regular))
        pdfmetrics.registerFont(TTFont("SupaSansBold", bold))
        FONT, FONT_BOLD = "SupaSans", "SupaSansBold"
        if Path(mono).exists():
            pdfmetrics.registerFont(TTFont("SupaMono", mono)); MONO = "SupaMono"
        break


class ArchitecturePlate(Flowable):
    def __init__(self, width=166*mm, height=82*mm):
        super().__init__(); self.width = width; self.height = height

    def draw(self):
        c = self.canv
        c.setFillColor(SURFACE); c.roundRect(0, 0, self.width, self.height, 4*mm, fill=1, stroke=0)
        boxes = [
            (8, 57, 150, 16, "PERIPHERY", "Router  |  Position Manager  |  Quoter"),
            (8, 34, 72, 17, "SHARED VAULT", "Custody  |  Claims  |  Deltas"),
            (86, 34, 72, 17, "POOL MANAGER", "Pool identity  |  Dispatch  |  Fees"),
            (8, 9, 45, 18, "CLAMM", "Ticks + ranges"),
            (60, 9, 45, 18, "BIN AMM", "Active-bin inventory"),
            (112, 9, 46, 18, "STABLE", "Amplified invariant"),
        ]
        for x,y,w,h,title,sub in boxes:
            x*=mm; y*=mm; w*=mm; h*=mm
            c.setFillColor(BG); c.setStrokeColor(LINE); c.roundRect(x,y,w,h,2*mm,fill=1,stroke=1)
            c.setFillColor(ACCENT); c.setFont(FONT_BOLD,7); c.drawString(x+3*mm,y+h-5*mm,title)
            c.setFillColor(MUTED); c.setFont(FONT,6.5); c.drawString(x+3*mm,y+4*mm,sub)
        c.setStrokeColor(ACCENT); c.setLineWidth(.7)
        for x1,y1,x2,y2 in [(83,57,83,51),(122,34,31,27),(122,34,82,27),(122,34,135,27)]:
            c.line(x1*mm,y1*mm,x2*mm,y2*mm)


def styles():
    s = getSampleStyleSheet()
    s.add(ParagraphStyle(name="CoverKicker", fontName=FONT_BOLD, fontSize=9, leading=12, textColor=ACCENT, spaceAfter=18))
    s.add(ParagraphStyle(name="CoverTitle", fontName=FONT_BOLD, fontSize=34, leading=38, textColor=INK, spaceAfter=12))
    s.add(ParagraphStyle(name="CoverSub", fontName=FONT, fontSize=14, leading=20, textColor=MUTED, spaceAfter=30))
    s.add(ParagraphStyle(name="H1x", fontName=FONT_BOLD, fontSize=22, leading=27, textColor=INK, spaceBefore=13, spaceAfter=9))
    s.add(ParagraphStyle(name="H2x", fontName=FONT_BOLD, fontSize=15, leading=19, textColor=ACCENT, spaceBefore=11, spaceAfter=6))
    s.add(ParagraphStyle(name="H3x", fontName=FONT_BOLD, fontSize=11, leading=15, textColor=INK, spaceBefore=8, spaceAfter=4))
    s.add(ParagraphStyle(name="Bodyx", fontName=FONT, fontSize=9.2, leading=14.2, textColor=INK, spaceAfter=7))
    s.add(ParagraphStyle(name="Smallx", fontName=FONT, fontSize=7.5, leading=11, textColor=MUTED, spaceAfter=4))
    s.add(ParagraphStyle(name="Callout", fontName=FONT, fontSize=8.5, leading=13, textColor=INK, backColor=SURFACE, borderColor=ACCENT, borderWidth=.6, borderPadding=8, spaceBefore=5, spaceAfter=9))
    s.add(ParagraphStyle(name="Codex", fontName=MONO, fontSize=7.3, leading=10.5, textColor=colors.HexColor("#C9E7F5"), backColor=SURFACE, borderPadding=7, spaceAfter=8))
    return s


def esc(text):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r"<font name='%s'>\1</font>" % MONO, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def parse_markdown(text, s):
    story, para, code = [], [], []
    def flush_para():
        if para:
            story.append(Paragraph(esc(" ".join(x.strip() for x in para)), s["Bodyx"])); para.clear()
    def flush_code():
        if code:
            story.append(Preformatted("\n".join(code), s["Codex"])); code.clear()
    in_code = False
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("```"):
            if in_code: flush_code()
            else: flush_para()
            in_code = not in_code; continue
        if in_code: code.append(line); continue
        if not line: flush_para(); continue
        if line.startswith("# "):
            flush_para(); story.append(PageBreak()); story.append(Paragraph(esc(line[2:]), s["H1x"])); continue
        if line.startswith("## "):
            flush_para(); story.append(Paragraph(esc(line[3:]), s["H1x"])); continue
        if line.startswith("### "):
            flush_para(); story.append(Paragraph(esc(line[4:]), s["H2x"])); continue
        if line.startswith("#### "):
            flush_para(); story.append(Paragraph(esc(line[5:]), s["H3x"])); continue
        if line.startswith("> "):
            flush_para(); story.append(Paragraph(esc(line[2:]), s["Callout"])); continue
        if line.startswith("- "):
            flush_para(); story.append(Paragraph("• " + esc(line[2:]), s["Bodyx"])); continue
        if re.match(r"^\d+\. ", line):
            flush_para(); story.append(Paragraph(esc(line), s["Bodyx"])); continue
        if line.startswith("|"):
            flush_para(); story.append(Paragraph(esc(line.replace("|", "  |  ")), s["Smallx"])); continue
        para.append(line)
    flush_para(); flush_code(); return story


class SupaDoc(BaseDocTemplate):
    def __init__(self, path, title):
        self.doc_title = title
        super().__init__(str(path), pagesize=A4, leftMargin=22*mm, rightMargin=22*mm, topMargin=23*mm, bottomMargin=20*mm, title=title, author="SupaDAO DEX")
        frame = Frame(self.leftMargin, self.bottomMargin, self.width, self.height, id="content")
        self.addPageTemplates(PageTemplate(id="main", frames=frame, onPage=self.decorate))
    def decorate(self, c, doc):
        c.saveState(); c.setFillColor(BG); c.rect(0,0,A4[0],A4[1],fill=1,stroke=0)
        if doc.page > 1:
            c.setStrokeColor(LINE); c.line(22*mm, A4[1]-15*mm, A4[0]-22*mm, A4[1]-15*mm)
            c.setFillColor(MUTED); c.setFont(FONT, 7)
            c.drawString(22*mm, A4[1]-11*mm, self.doc_title.upper())
            c.drawRightString(A4[0]-22*mm, 11*mm, f"SUPADAO DEX  /  {doc.page:02d}")
        c.restoreState()


def cover(title, subtitle, s):
    return [
        Spacer(1, 22*mm),
        Paragraph("SUPADAO DEX  /  TECHNICAL PUBLICATION", s["CoverKicker"]),
        Paragraph(title, s["CoverTitle"]),
        Paragraph(subtitle, s["CoverSub"]),
        ArchitecturePlate(), Spacer(1, 16*mm),
        Paragraph("VERSION 1.0.0  ·  15 OCTOBER 2026  ·  UNDER TECHNICAL REVIEW", s["Smallx"]),
        Spacer(1, 3*mm),
        Paragraph("Repository-derived documentation. No independent audit or public deployment was confirmed.", s["Callout"]),
        PageBreak(),
        Paragraph("Document control", s["H1x"]),
        Paragraph("This publication is reproducible from Markdown sources in the SupaDAO DEX repository. It describes inspected source and is not legal, tax or investment advice.", s["Bodyx"]),
        Paragraph("Contents", s["H2x"]),
    ]


PUBLICATIONS = [
    ("docs/whitepaper/SUPADAO_DEX_WHITEPAPER.md", "SupaDAO_DEX_Whitepaper.pdf", "SupaDAO DEX White Paper", "A unified singleton exchange architecture for multiple liquidity regimes"),
    ("docs/protocol/PROTOCOL_ARCHITECTURE_GUIDE.md", "SupaDAO_DEX_Protocol_Architecture.pdf", "Protocol & Architecture", "Shared settlement, specialized curve engines, explicit trust boundaries"),
    ("docs/users/USER_GUIDE.md", "SupaDAO_DEX_User_Guide.pdf", "User Guide", "Trading, liquidity models, claims, fees and risks"),
    ("docs/developers/DEVELOPER_DOCUMENTATION.md", "SupaDAO_DEX_Developer_Documentation.pdf", "Developer Documentation", "Contracts, integration paths, testing and deployment controls"),
    ("docs/TECHNICAL_BRIEF.md", "SupaDAO_DEX_Technical_Brief.pdf", "Technical Brief", "Architecture, evidence, constraints and validation milestones"),
]


def main():
    DIST.mkdir(exist_ok=True); MIRROR.mkdir(parents=True, exist_ok=True); LANDING.mkdir(parents=True, exist_ok=True)
    s = styles()
    for source, filename, title, subtitle in PUBLICATIONS:
        markdown = (ROOT / source).read_text(encoding="utf-8")
        # Avoid duplicating the source title on page 3.
        markdown = re.sub(r"^# .+?\n", "", markdown, count=1)
        story = cover(title, subtitle, s)
        headings = re.findall(r"^##?\s+(.+)$", markdown, flags=re.M)
        story.append(Paragraph("<br/>".join(f"{i+1:02d}  {esc(h)}" for i,h in enumerate(headings[:18])), s["Bodyx"]))
        story.append(PageBreak()); story.extend(parse_markdown(markdown, s))
        out = DIST / filename
        SupaDoc(out, title).build(story)
        shutil.copy2(out, MIRROR / filename)
    shutil.copy2(DIST / "SupaDAO_DEX_Whitepaper.pdf", LANDING / "SupaDAO_DEX_Whitepaper.pdf")


if __name__ == "__main__":
    main()
