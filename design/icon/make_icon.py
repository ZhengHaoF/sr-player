# -*- coding: utf-8 -*-
"""SR Player 应用图标概念生成器。

程序化绘制（不依赖 AI 生图与 numpy），4x 超采样抗锯齿，输出 1024x1024 RGBA PNG
（圆角方形外透明，可直接作为 Android/Windows 图标源图）。

用法：python design/icon/make_icon.py
输出：design/icon/concept-{a,b,c}.png
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

S = 1024                 # 输出尺寸
SS = 4                   # 超采样倍数
W = S * SS

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_PATH = os.path.normpath(
    os.path.join(HERE, "..", "..", "assets", "fonts", "MiSans-Semibold.ttf"))

# 品牌色（与应用内网盘/播放主题一致）
INDIGO = (79, 70, 229)     # #4F46E5
VIOLET = (124, 58, 237)    # #7C3AED
SLATE = (15, 23, 42)       # #0F172A
AMBER = (251, 191, 36)     # #FBBF24
ORANGE = (249, 115, 22)    # #F97316
WHITE = (255, 255, 255)

CORNER = int(W * 0.218)    # 圆角方形圆角（≈ iOS squircle 比例）


def diagonal_gradient(w, c1, c2):
    """左上(c1)→右下(c2) 对角渐变（逐对角线绘制，无需 numpy）。"""
    img = Image.new("RGB", (w, w))
    d = ImageDraw.Draw(img)
    n = 2 * w - 1
    for i in range(n):
        t = i / (n - 1)
        col = tuple(int(c1[k] + (c2[k] - c1[k]) * t) for k in range(3))
        if i < w:
            p1, p2 = (i, 0), (0, i)
        else:
            p1, p2 = (w - 1, i - (w - 1)), (i - (w - 1), w - 1)
        d.line([p1, p2], fill=col, width=SS * 3)
    return img


def rounded_square_mask(w, radius):
    m = Image.new("L", (w, w), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, w - 1, w - 1], radius=radius, fill=255)
    return m


def rounded_poly(pts, r, per_arc=12):
    """凸多边形圆角化：每个角替换为内切圆弧采样点（Minkowski 圆角）。"""
    n = len(pts)
    out = []
    for i in range(n):
        p_prev, p_cur, p_next = pts[(i - 1) % n], pts[i], pts[(i + 1) % n]
        e1 = (p_cur[0] - p_prev[0], p_cur[1] - p_prev[1])
        e2 = (p_next[0] - p_cur[0], p_next[1] - p_cur[1])
        l1 = math.hypot(*e1)
        l2 = math.hypot(*e2)
        u1 = (e1[0] / l1, e1[1] / l1)
        u2 = (e2[0] / l2, e2[1] / l2)
        # 内角 θ：入边反向与出边的夹角
        cos_t = max(-1.0, min(1.0, -(u1[0] * u2[0] + u1[1] * u2[1])))
        theta = math.acos(cos_t)
        # 内角平分线（指向多边形内部）
        bx, by = -u1[0] + u2[0], -u1[1] + u2[1]
        bl = math.hypot(bx, by)
        bx, by = bx / bl, by / bl
        # 圆心：距顶点 r / sin(θ/2)；切点：沿边距顶点 r / tan(θ/2)
        d = r / math.sin(theta / 2)
        c = (p_cur[0] + bx * d, p_cur[1] + by * d)
        t_len = r / math.tan(theta / 2)
        tp1 = (p_cur[0] - u1[0] * t_len, p_cur[1] - u1[1] * t_len)
        tp2 = (p_cur[0] + u2[0] * t_len, p_cur[1] + u2[1] * t_len)
        a1 = math.atan2(tp1[1] - c[1], tp1[0] - c[0])
        a2 = math.atan2(tp2[1] - c[1], tp2[0] - c[0])
        da = (a2 - a1) % (2 * math.pi)
        if da > math.pi:
            da -= 2 * math.pi
        for k in range(per_arc + 1):
            a = a1 + da * k / per_arc
            out.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a)))
    return out


def sparkle_pts(cx, cy, r_out, r_in, rot=-math.pi / 2):
    """四角星光（8 点多边形：外内交替）。"""
    pts = []
    for i in range(8):
        ang = rot + i * math.pi / 4
        rr = r_out if i % 2 == 0 else r_in
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    return pts


def play_triangle(cx, cy, hw, hh, r):
    """朝右圆角播放三角（hw/hh = 半宽/半高）。"""
    pts = [(cx - hw, cy - hh), (cx - hw, cy + hh), (cx + hw, cy)]
    return rounded_poly(pts, r)


def cloud_mask(w, box):
    """云朵 mask：底座圆角矩形 + 三圆联合，中央镂空播放三角。"""
    m = Image.new("L", (w, w), 0)
    d = ImageDraw.Draw(m)
    x0, y0, x1, y1 = box
    ch = y1 - y0
    cw = x1 - x0
    d.rounded_rectangle([x0, y0 + int(ch * 0.34), x1, y1],
                        radius=int(ch * 0.33), fill=255)
    d.ellipse([x0, y0 + int(ch * 0.12), x0 + int(cw * 0.55), y1 - int(ch * 0.04)],
              fill=255)
    d.ellipse([x0 + int(cw * 0.26), y0, x0 + int(cw * 0.74), y0 + int(ch * 0.80)],
              fill=255)
    d.ellipse([x0 + int(cw * 0.48), y0 + int(ch * 0.16), x1, y1 - int(ch * 0.10)],
              fill=255)
    # 镂空播放三角（透出底色渐变）
    tri = play_triangle((x0 + x1) / 2 + w * 0.008, (y0 + y1) / 2,
                        ch * 0.27, ch * 0.30, ch * 0.09)
    d.polygon(tri, fill=0)
    return m


def base_canvas(bg, mask):
    """渐变背景经圆角方形 mask 裁形。"""
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    canvas.paste(bg, (0, 0), mask)
    return canvas


def concept_a():
    """A「SR 播放键」：渐变底 + 白色圆角播放三角 + 琥珀星光。"""
    canvas = base_canvas(diagonal_gradient(W, INDIGO, VIOLET),
                         rounded_square_mask(W, CORNER))
    d = ImageDraw.Draw(canvas)
    tri = play_triangle(W * 0.52, W * 0.50, W * 0.185, W * 0.21, W * 0.042)
    d.polygon(tri, fill=WHITE + (255,))
    spark = sparkle_pts(W * 0.795, W * 0.27, W * 0.055, W * 0.021,
                        rot=-math.pi / 4)
    d.polygon(spark, fill=AMBER + (255,))
    return canvas


def concept_b():
    """B「云端播放」：渐变底 + 白云朵剪影中央镂空播放三角。"""
    canvas = base_canvas(diagonal_gradient(W, INDIGO, VIOLET),
                         rounded_square_mask(W, CORNER))
    cm = cloud_mask(W, (int(W * 0.21), int(W * 0.30),
                        int(W * 0.79), int(W * 0.70)))
    white = Image.new("RGBA", (W, W), WHITE + (255,))
    canvas.paste(white, (0, 0), cm)
    return canvas


def concept_c():
    """C「暗夜放映」：暗夜底 + 琥珀渐变圆角三角 + MiSans「SR」字标。"""
    canvas = base_canvas(Image.new("RGB", (W, W), SLATE),
                         rounded_square_mask(W, CORNER))
    grad = diagonal_gradient(W, AMBER, ORANGE)
    tri_mask = Image.new("L", (W, W), 0)
    td = ImageDraw.Draw(tri_mask)
    tri = play_triangle(W * 0.50, W * 0.40, W * 0.20, W * 0.225, W * 0.046)
    td.polygon(tri, fill=255)
    canvas.paste(grad, (0, 0), tri_mask)
    spark_mask = Image.new("L", (W, W), 0)
    sd = ImageDraw.Draw(spark_mask)
    sd.polygon(sparkle_pts(W * 0.80, W * 0.22, W * 0.05, W * 0.019), fill=255)
    canvas.paste(grad, (0, 0), spark_mask)
    font = ImageFont.truetype(FONT_PATH, int(W * 0.15))
    d = ImageDraw.Draw(canvas)
    d.text((W * 0.5, W * 0.765), "SR", font=font, fill=WHITE + (255,),
           anchor="mm")
    return canvas


def adaptive_layers():
    """Android 自适应图标分层：背景=全幅渐变，前景=安全区内的图形。

    安全区：可见圆直径约为画布的 66%，所有内容需落在中心半径 0.33W 内。
    """
    bg = diagonal_gradient(W, INDIGO, VIOLET)
    fg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    tri = play_triangle(W * 0.515, W * 0.5, W * 0.14, W * 0.16, W * 0.032)
    d.polygon(tri, fill=WHITE + (255,))
    spark = sparkle_pts(W * 0.70, W * 0.33, W * 0.042, W * 0.016,
                        rot=-math.pi / 4)
    d.polygon(spark, fill=AMBER + (255,))
    return bg, fg


def main():
    for name, fn in (("concept-a", concept_a), ("concept-b", concept_b),
                     ("concept-c", concept_c)):
        img = fn().resize((S, S), Image.LANCZOS)
        out = os.path.join(HERE, f"{name}.png")
        img.save(out)
        print("saved", out)
    # Android 自适应图标分层（flutter_launcher_icons 用）
    bg, fg = adaptive_layers()
    bg.resize((S, S), Image.LANCZOS).save(os.path.join(HERE, "adaptive-bg.png"))
    fg.resize((S, S), Image.LANCZOS).save(os.path.join(HERE, "adaptive-fg.png"))
    print("saved adaptive-bg.png / adaptive-fg.png")


if __name__ == "__main__":
    main()
