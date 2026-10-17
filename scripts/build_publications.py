#!/usr/bin/env python3
"""Build the versioned SupaDAO DEX PDF publication set with official SupaDAO branding."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.platypus import (
    BaseDocTemplate, Frame, PageTemplate, Paragraph, Spacer, PageBreak,
    Table, Preformatted, Flowable, Image
)

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
MIRROR = ROOT / "output" / "pdf"
LANDING = ROOT.parent / "landing" / "public" / "documents"
LOGO_IMG = ROOT.parent / "landing" / "public" / "assets" / "images" / "supadao-logo.png"
WORDMARK_IMG = ROOT.parent / "landing" / "public" / "assets" / "images" / "supadao-wordmark.png"

# SupaDAO Official Brand Color Palette
BG = colors.HexColor("#08090B")         # Obsidian Dark Base
SURFACE = colors.HexColor("#111317")    # Graphite Slate Surface
SURFACE_CARD = colors.HexColor("#161A22") # Elevated Card Surface
INK = colors.HexColor("#F3F4F6")        # Pure Crisp White Text
MUTED = colors.HexColor("#9CA3AF")      # Subtle Secondary Gray
PURPLE = colors.HexColor("#A855F7")     # SupaDAO Electric Purple Accent
PURPLE_LIGHT = colors.HexColor("#C084FC")
LIME = colors.HexColor("#22C55E")       # SupaDAO Emerald/Lime Brand Accent
LIME_GLOW = colors.HexColor("#4ADE80")
LINE = colors.HexColor("#1F242D")       # Hairline Border
LINE_ACTIVE = colors.HexColor("#374151")
WARN = colors.HexColor("#FBBF24")       # Amber Warning

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
    """Branded Vector Architecture Diagram matching SupaDAO Aesthetic."""
    def __init__(self, width=166*mm, height=78*mm):
        super().__init__()
        self.width = width
        self.height = height

    def draw(self):
        c = self.canv
        # Main plate card
        c.setFillColor(SURFACE)
        c.setStrokeColor(LINE_ACTIVE)
        c.roundRect(0, 0, self.width, self.height, 4*mm, fill=1, stroke=1)

        # Subtle gradient grid lines
        c.setStrokeColor(colors.HexColor("#1A202C"))
        c.setLineWidth(0.4)
        for i in range(1, 5):
            c.line(0, i * 15 * mm, self.width, i * 15 * mm)

        boxes = [
            (8, 54, 150, 16, "PERIPHERY & ROUTING", "SupaRouter  |  SupaPositionManager (NFT)  |  SupaQuoter  |  SupaClaimsRouter", LIME),
            (8, 32, 72, 17, "SHARED VAULT", "Token Custody  |  ERC-6909 Claims  |  EIP-1153 Zero-Delta Flash Ledger", PURPLE),
            (86, 32, 72, 17, "POOL MANAGER GATEWAY", "PoolKey Hashing  |  Lifecycle Dispatch  |  Protocol Fees  |  Breakers", LIME),
            (8, 8, 46, 18, "CLAMM ENGINE", "Q64.96 Concentrated Ticks & Ranges", PURPLE),
            (60, 8, 46, 18, "BIN AMM ENGINE", "Discretized Zero-Slippage Bins", LIME),
            (112, 8, 46, 18, "STABLE AMM ENGINE", "Amplified Newton-Raphson Curve", PURPLE),
        ]
        for x, y, w, h, title, sub, accent in boxes:
            x *= mm; y *= mm; w *= mm; h *= mm
            c.setFillColor(SURFACE_CARD)
            c.setStrokeColor(LINE_ACTIVE)
            c.roundRect(x, y, w, h, 2*mm, fill=1, stroke=1)
            # Accent header pip
            c.setFillColor(accent)
            c.rect(x + 2*mm, y + h - 5.5*mm, 2*mm, 2*mm, fill=1, stroke=0)
            c.setFont(FONT_BOLD, 7)
            c.drawString(x + 5.5*mm, y + h - 5.2*mm, title)
            c.setFillColor(MUTED)
            c.setFont(FONT, 5.8)
            c.drawString(x + 2.5*mm, y + 3.8*mm, sub)

        # Connecting architectural circuit lines
        c.setStrokeColor(PURPLE)
        c.setLineWidth(0.8)
        c.line(83*mm, 54*mm, 83*mm, 49*mm)
        c.line(44*mm, 32*mm, 44*mm, 26*mm)
        c.line(122*mm, 32*mm, 31*mm, 26*mm)
        c.line(122*mm, 32*mm, 83*mm, 26*mm)
        c.line(122*mm, 32*mm, 135*mm, 26*mm)


def styles():
    s = getSampleStyleSheet()
    s.add(ParagraphStyle(name="CoverKicker", fontName=FONT_BOLD, fontSize=8.5, leading=12, textColor=LIME, spaceAfter=14))
    s.add(ParagraphStyle(name="CoverTitle", fontName=FONT_BOLD, fontSize=30, leading=34, textColor=INK, spaceAfter=10))
    s.add(ParagraphStyle(name="CoverSub", fontName=FONT, fontSize=13, leading=18, textColor=MUTED, spaceAfter=22))
    s.add(ParagraphStyle(name="H1x", fontName=FONT_BOLD, fontSize=19, leading=23, textColor=INK, spaceBefore=14, spaceAfter=8))
    s.add(ParagraphStyle(name="H2x", fontName=FONT_BOLD, fontSize=13.5, leading=17, textColor=PURPLE_LIGHT, spaceBefore=11, spaceAfter=5))
    s.add(ParagraphStyle(name="H3x", fontName=FONT_BOLD, fontSize=10.5, leading=14, textColor=LIME_GLOW, spaceBefore=8, spaceAfter=4))
    s.add(ParagraphStyle(name="Bodyx", fontName=FONT, fontSize=9.0, leading=13.8, textColor=INK, spaceAfter=6.5))
    s.add(ParagraphStyle(name="Smallx", fontName=FONT, fontSize=7.2, leading=10.5, textColor=MUTED, spaceAfter=4))
    s.add(ParagraphStyle(name="Callout", fontName=FONT, fontSize=8.2, leading=12.5, textColor=INK, backColor=SURFACE_CARD, borderColor=PURPLE, borderWidth=0.7, borderPadding=8, spaceBefore=6, spaceAfter=9))
    s.add(ParagraphStyle(name="Codex", fontName=MONO, fontSize=7.2, leading=10.2, textColor=LIME_GLOW, backColor=SURFACE_CARD, borderPadding=6, spaceAfter=7))
    return s


def esc(text):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r"<font name='%s' color='%s'>\1</font>" % (MONO, LIME_GLOW.hexval()), text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def parse_markdown(text, s):
    story, para, code = [], [], []
    def flush_para():
        if para:
            story.append(Paragraph(esc(" ".join(x.strip() for x in para)), s["Bodyx"]))
            para.clear()
    def flush_code():
        if code:
            story.append(Preformatted("\n".join(code), s["Codex"]))
            code.clear()
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
            flush_para(); story.append(Paragraph("<font color='%s'>▪</font> " % LIME.hexval() + esc(line[2:]), s["Bodyx"])); continue
        if re.match(r"^\d+\. ", line):
            flush_para(); story.append(Paragraph(esc(line), s["Bodyx"])); continue
        if line.startswith("|"):
            flush_para(); story.append(Paragraph(esc(line.replace("|", "  |  ")), s["Smallx"])); continue
        para.append(line)
    flush_para(); flush_code(); return story


class SupaDoc(BaseDocTemplate):
    def __init__(self, path, title):
        self.doc_title = title
        super().__init__(str(path), pagesize=A4, leftMargin=20*mm, rightMargin=20*mm, topMargin=22*mm, bottomMargin=20*mm, title=title, author="SupaDAO DEX")
        frame = Frame(self.leftMargin, self.bottomMargin, self.width, self.height, id="content")
        self.addPageTemplates(PageTemplate(id="main", frames=frame, onPage=self.decorate))

    def decorate(self, c, doc):
        c.saveState()
        # Dark Obsidian background
        c.setFillColor(BG)
        c.rect(0, 0, A4[0], A4[1], fill=1, stroke=0)

        # Subtle brand accent border stripe at the very top of each page
        c.setFillColor(PURPLE)
        c.rect(0, A4[1] - 2*mm, A4[0] * 0.45, 2*mm, fill=1, stroke=0)
        c.setFillColor(LIME)
        c.rect(A4[0] * 0.45, A4[1] - 2*mm, A4[0] * 0.55, 2*mm, fill=1, stroke=0)

        if doc.page > 1:
            # Header
            c.setStrokeColor(LINE)
            c.setLineWidth(0.6)
            c.line(20*mm, A4[1]-14*mm, A4[0]-20*mm, A4[1]-14*mm)
            
            # Mini brand logo icon in header
            if LOGO_IMG.exists():
                c.drawImage(str(LOGO_IMG), 20*mm, A4[1]-12.5*mm, width=5*mm, height=5*mm, mask='auto')
                c.setFillColor(PURPLE_LIGHT)
                c.setFont(FONT_BOLD, 7)
                c.drawString(27*mm, A4[1]-10*mm, "SUPADAO")
                c.setFillColor(MUTED)
                c.setFont(FONT, 7)
                c.drawString(42*mm, A4[1]-10*mm, "·  " + self.doc_title.upper())
            else:
                c.setFillColor(MUTED)
                c.setFont(FONT, 7)
                c.drawString(20*mm, A4[1]-10*mm, self.doc_title.upper())

            # Footer
            c.setStrokeColor(LINE)
            c.setLineWidth(0.6)
            c.line(20*mm, 15*mm, A4[0]-20*mm, 15*mm)

            c.setFillColor(MUTED)
            c.setFont(FONT, 6.5)
            c.drawString(20*mm, 10.5*mm, "SUPADAO DEX RESEARCH  ·  EVIDENCE-DERIVED SPECIFICATION")

            # Page numbering pill
            c.setFillColor(SURFACE_CARD)
            c.roundRect(A4[0]-35*mm, 8.5*mm, 15*mm, 5.5*mm, 1.5*mm, fill=1, stroke=0)
            c.setFillColor(LIME_GLOW)
            c.setFont(FONT_BOLD, 7)
            c.drawRightString(A4[0]-22*mm, 10.2*mm, f"{doc.page:02d}")

        c.restoreState()


def cover(title, subtitle, s):
    story = [Spacer(1, 14*mm)]

    # Header with official SupaDAO Logo and Wordmark
    if LOGO_IMG.exists():
        story.append(Image(str(LOGO_IMG), width=18*mm, height=18*mm))
        story.append(Spacer(1, 4*mm))

    story.extend([
        Paragraph("SUPADAO DEX  /  OFFICIAL PROTOCOL PUBLICATION", s["CoverKicker"]),
        Paragraph(title, s["CoverTitle"]),
        Paragraph(subtitle, s["CoverSub"]),
        ArchitecturePlate(),
        Spacer(1, 10*mm),
        Paragraph("VERSION 1.0.0  ·  15 OCTOBER 2026  ·  UNDER TECHNICAL REVIEW", s["Smallx"]),
        Spacer(1, 2*mm),
        Paragraph("<b>Institutional Notice</b>: Repository-derived documentation based on audited smart contract implementations. No independent external audit or public deployment was confirmed.", s["Callout"]),
        PageBreak(),
        Paragraph("Document Control & Verification Status", s["H1x"]),
        Paragraph("This technical publication is reproducible directly from verified Markdown specifications in the SupaDAO DEX repository. It describes inspected smart contract code and does not constitute legal, tax, or investment advice.", s["Bodyx"]),
        Paragraph("Contents & Architecture Sections", s["H2x"]),
    ])
    return story


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
        markdown = re.sub(r"^# .+?\n", "", markdown, count=1)
        story = cover(title, subtitle, s)
        headings = re.findall(r"^##?\s+(.+)$", markdown, flags=re.M)
        story.append(Paragraph("<br/>".join(f"<font color='{LIME.hexval()}'>{i+1:02d}</font>  {esc(h)}" for i, h in enumerate(headings[:18])), s["Bodyx"]))
        story.append(PageBreak())
        story.extend(parse_markdown(markdown, s))
        out = DIST / filename
        SupaDoc(out, title).build(story)
        shutil.copy2(out, MIRROR / filename)
    shutil.copy2(DIST / "SupaDAO_DEX_Whitepaper.pdf", LANDING / "SupaDAO_DEX_Whitepaper.pdf")


if __name__ == "__main__":
    main()
