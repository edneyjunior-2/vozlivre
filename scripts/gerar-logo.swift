#!/usr/bin/env swift
// Desenha a logo do VozLivre e exporta os PNGs e o .icns do aplicativo.
//
// A logo é a própria cara do app em uso: a pílula escura com o microfone e a onda
// de voz em verde, que aparece flutuando na tela enquanto ele está ouvindo.
//
// uso: swift scripts/gerar-logo.swift <pasta-de-saida>

import AppKit
import Foundation

let saida = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: saida, withIntermediateDirectories: true)

let verde = NSColor(srgbRed: 0.22, green: 0.85, blue: 0.42, alpha: 1)      // verde do HUD
let verdeEscuro = NSColor(srgbRed: 0.11, green: 0.55, blue: 0.28, alpha: 1)

/// Desenha a logo num canvas quadrado de lado `lado`.
/// `fundo` = true desenha o quadrado arredondado (ícone do app);
/// false deixa transparente (logo para o README).
func desenhar(lado: CGFloat, fundo: Bool, claro: Bool = false) -> NSImage {
    let imagem = NSImage(size: NSSize(width: lado, height: lado))
    imagem.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { imagem.unlockFocus(); return imagem }
    ctx.setShouldAntialias(true)

    let u = lado / 100.0   // unidade relativa: tudo é descrito em % do lado

    if fundo {
        // Quadrado arredondado no padrão dos ícones do macOS.
        let margem = 4 * u
        let corpo = NSRect(x: margem, y: margem, width: lado - margem * 2, height: lado - margem * 2)
        let caminho = NSBezierPath(roundedRect: corpo, xRadius: 22 * u, yRadius: 22 * u)
        caminho.addClip()

        let gradiente = NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.17, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        ])
        gradiente?.draw(in: corpo, angle: -90)

        // Brilho sutil na borda superior, como nos ícones do sistema.
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let borda = NSBezierPath(roundedRect: corpo.insetBy(dx: 0.5 * u, dy: 0.5 * u),
                                 xRadius: 21 * u, yRadius: 21 * u)
        borda.lineWidth = 1 * u
        borda.stroke()
    }

    let corPrincipal = (fundo || !claro) ? verde : verdeEscuro

    // Toda a composição vive entre 20% e 82% do lado, centrada na metade vertical —
    // margem suficiente para o recorte arredondado do ícone não cortar nada.
    let meio = 50 * u
    let traco = 3.6 * u

    // --- Microfone (lado esquerdo) ---
    corPrincipal.setFill()
    let capsulaLargura = 12 * u
    let capsulaAltura = 24 * u
    let capsulaCentroX = 27 * u
    // A cápsula fica acima do meio; haste e base descem, equilibrando o conjunto.
    NSBezierPath(roundedRect: NSRect(x: capsulaCentroX - capsulaLargura / 2,
                                     y: meio - 2 * u,
                                     width: capsulaLargura, height: capsulaAltura),
                 xRadius: capsulaLargura / 2, yRadius: capsulaLargura / 2).fill()

    corPrincipal.setStroke()
    // Arco que abraça a cápsula por baixo.
    let arco = NSBezierPath()
    arco.appendArc(withCenter: NSPoint(x: capsulaCentroX, y: meio + 3 * u), radius: 12 * u,
                   startAngle: 202, endAngle: 338, clockwise: false)
    arco.lineWidth = traco
    arco.lineCapStyle = .round
    arco.stroke()

    let haste = NSBezierPath()
    haste.move(to: NSPoint(x: capsulaCentroX, y: meio - 9 * u))
    haste.line(to: NSPoint(x: capsulaCentroX, y: meio - 18 * u))
    haste.lineWidth = traco
    haste.lineCapStyle = .round
    haste.stroke()

    let base = NSBezierPath()
    base.move(to: NSPoint(x: capsulaCentroX - 8 * u, y: meio - 18 * u))
    base.line(to: NSPoint(x: capsulaCentroX + 8 * u, y: meio - 18 * u))
    base.lineWidth = traco
    base.lineCapStyle = .round
    base.stroke()

    // --- Onda de voz (lado direito) ---
    // Quatro barras só: em 16 pixels, mais que isso vira borrão.
    // Alturas irregulares de propósito — fala real não é simétrica.
    let alturas: [CGFloat] = [20, 42, 30, 14]
    let larguraBarra = 6 * u
    let espaco = 4.5 * u
    var x = 49 * u
    for (i, altura) in alturas.enumerated() {
        let h = altura * u
        let rect = NSRect(x: x, y: meio - h / 2, width: larguraBarra, height: h)
        // A barra mais alta é a mais acesa, como no app quando a voz sobe.
        let intensidade: CGFloat = altura > 35 ? 1.0 : (altura > 25 ? 0.85 : 0.6)
        corPrincipal.withAlphaComponent(intensidade).setFill()
        NSBezierPath(roundedRect: rect, xRadius: larguraBarra / 2, yRadius: larguraBarra / 2).fill()
        x += larguraBarra + espaco
        _ = i
    }

    imagem.unlockFocus()
    return imagem
}

func salvar(_ imagem: NSImage, em caminho: String) {
    guard let tiff = imagem.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: caminho))
}

// Ícone do app, em todos os tamanhos que o macOS pede.
let conjunto = "\(saida)/VozLivre.iconset"
try? FileManager.default.createDirectory(atPath: conjunto, withIntermediateDirectories: true)
for (lado, nome) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    salvar(desenhar(lado: CGFloat(lado), fundo: true), em: "\(conjunto)/icon_\(nome).png")
}

// Versões para o README: com fundo (funciona em qualquer tema) e sem.
salvar(desenhar(lado: 512, fundo: true), em: "\(saida)/logo.png")
salvar(desenhar(lado: 1024, fundo: true), em: "\(saida)/logo@2x.png")
salvar(desenhar(lado: 512, fundo: false, claro: false), em: "\(saida)/logo-escuro.png")
salvar(desenhar(lado: 512, fundo: false, claro: true), em: "\(saida)/logo-claro.png")

print("gerado em \(saida)")
