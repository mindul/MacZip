// 맥집(MacZip) 앱 아이콘(지퍼 알에서 고개를 내민 병아리)을 1024×1024 PNG로 그린다.
// 사용: swiftc -O scripts/icon/AppIcon.swift -o /tmp/appicon && /tmp/appicon 출력.png
// 보통은 scripts/make-icon.sh 로 실행한다.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let yellow = rgb(0xFFD43B), yellowDark = rgb(0xF2B705), beak = rgb(0xFF8A3D), eye = rgb(0x3B2A20)
let blush = rgb(0xFF8FA3, 0.55), silver = rgb(0xA7AFBA), silverDark = rgb(0x6E7682), white = rgb(0xFFFFFF)

func context(_ size: Int) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setShouldAntialias(true)
    c.interpolationQuality = .high
    return c
}

func save(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

func fillEllipse(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
    c.setFillColor(color)
    c.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

/// macOS 아이콘 배경: 824 정사각 둥근 사각형 + 세로 그라데이션 + 그림자
func background(_ c: CGContext, _ top: UInt32, _ bottom: UInt32) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.25))
    c.addPath(path); c.setFillColor(rgb(bottom)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()
}

/// 병아리 얼굴(눈, 하이라이트, 부리, 볼터치)
func face(_ c: CGContext, cx: CGFloat, cy: CGFloat, scale s: CGFloat) {
    for dx in [-72.0, 72.0] {
        fillEllipse(c, cx + dx * s, cy, 24 * s, 27 * s, eye)
        fillEllipse(c, cx + dx * s + 8 * s, cy + 9 * s, 8 * s, 8 * s, white)
        fillEllipse(c, cx + dx * s * 1.55, cy - 42 * s, 34 * s, 20 * s, blush)
    }
    c.setFillColor(beak)
    c.setLineJoin(.round); c.setLineWidth(10 * s); c.setStrokeColor(beak)
    let by = cy - 40 * s
    c.move(to: CGPoint(x: cx - 30 * s, y: by + 8 * s))
    c.addLine(to: CGPoint(x: cx + 30 * s, y: by + 8 * s))
    c.addLine(to: CGPoint(x: cx, y: by - 26 * s))
    c.closePath()
    c.drawPath(using: .fillStroke)
}

/// 머리 꼭대기 깃털 세 가닥
func tuft(_ c: CGContext, cx: CGFloat, top: CGFloat, scale s: CGFloat) {
    fillEllipse(c, cx - 26 * s, top + 8 * s, 16 * s, 34 * s, yellow)
    fillEllipse(c, cx, top + 22 * s, 18 * s, 42 * s, yellow)
    fillEllipse(c, cx + 26 * s, top + 8 * s, 16 * s, 34 * s, yellow)
}

/// 가로 지퍼 이빨
func zipperH(_ c: CGContext, x0: CGFloat, x1: CGFloat, y: CGFloat, tooth: CGFloat) {
    var x = x0
    var up = true
    while x < x1 - tooth {
        let r = CGRect(x: x, y: up ? y : y - tooth * 1.1, width: tooth * 0.95, height: tooth * 1.1)
        let p = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        c.addPath(p); c.setFillColor(silver); c.fillPath()
        c.addPath(p); c.setStrokeColor(silverDark); c.setLineWidth(2.5); c.strokePath()
        x += tooth * 0.75; up.toggle()
    }
}

/// 세로 지퍼 이빨
func zipperV(_ c: CGContext, x: CGFloat, y0: CGFloat, y1: CGFloat, tooth: CGFloat) {
    var y = y0
    var left = true
    while y < y1 - tooth {
        let r = CGRect(x: left ? x - tooth * 1.1 : x, y: y, width: tooth * 1.1, height: tooth * 0.95)
        let p = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        c.addPath(p); c.setFillColor(silver); c.fillPath()
        c.addPath(p); c.setStrokeColor(silverDark); c.setLineWidth(2.5); c.strokePath()
        y += tooth * 0.75; left.toggle()
    }
}

/// 지퍼 손잡이(슬라이더 + 고리 탭)
func zipperPull(_ c: CGContext, x: CGFloat, y: CGFloat, length: CGFloat, width w: CGFloat) {
    let slider = CGPath(roundedRect: CGRect(x: x - w * 0.6, y: y - w * 0.5, width: w * 1.2, height: w), cornerWidth: 10, cornerHeight: 10, transform: nil)
    c.addPath(slider); c.setFillColor(silver); c.fillPath()
    c.addPath(slider); c.setStrokeColor(silverDark); c.setLineWidth(4); c.strokePath()
    let tab = CGPath(roundedRect: CGRect(x: x - w * 0.38, y: y - w * 0.3 - length, width: w * 0.76, height: length), cornerWidth: w * 0.38, cornerHeight: w * 0.38, transform: nil)
    c.addPath(tab); c.setFillColor(silver); c.fillPath()
    c.addPath(tab); c.setStrokeColor(silverDark); c.setLineWidth(4); c.strokePath()
    fillEllipse(c, x, y - w * 0.3 - length + w * 0.42, w * 0.16, w * 0.16, silverDark)
}

// A: 지퍼 알에서 고개 내민 병아리
func conceptA() -> CGImage {
    let c = context(1024)
    background(c, 0xCFEFFF, 0x7CC8F5)
    tuft(c, cx: 512, top: 742, scale: 1)
    fillEllipse(c, 512, 560, 215, 205, yellow)
    face(c, cx: 512, cy: 610, scale: 1)
    // 알 아랫부분(지퍼 선 위로는 잘라냄)
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 478))
    fillEllipse(c, 512, 410, 275, 262, rgb(0xFFF7E8))
    c.setStrokeColor(rgb(0xE6D3B3)); c.setLineWidth(8)
    c.strokeEllipse(in: CGRect(x: 512 - 275, y: 410 - 262, width: 550, height: 524))
    c.restoreGState()
    zipperH(c, x0: 262, x1: 772, y: 470, tooth: 26)
    zipperPull(c, x: 735, y: 470, length: 92, width: 50)
    // 알 테두리를 잡은 날개
    fillEllipse(c, 318, 468, 52, 34, yellowDark)
    fillEllipse(c, 668, 468, 52, 34, yellowDark)
    return c.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("사용법: AppIcon <출력.png>\n".data(using: .utf8)!)
    exit(2)
}
save(conceptA(), CommandLine.arguments[1])
