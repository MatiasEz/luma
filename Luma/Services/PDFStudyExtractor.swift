import AppKit
import Foundation
import PDFKit
import Vision

enum PDFStudyError: LocalizedError {
    case invalidPDF
    case emptyPDF
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .invalidPDF: "Luma no pudo abrir ese PDF."
        case .emptyPDF: "El PDF no contiene páginas."
        case .noReadableText: "No encontré texto legible en el PDF, ni siquiera usando reconocimiento visual."
        }
    }
}

struct PDFStudyExtractor: Sendable {
    func extract(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> ExtractedStudyDocument {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            guard let document = PDFDocument(url: url) else { throw PDFStudyError.invalidPDF }
            guard document.pageCount > 0 else { throw PDFStudyError.emptyPDF }

            var pages: [StudySourcePage] = []
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let pageNumber = index + 1
                await progress(
                    Double(index) / Double(max(1, document.pageCount)),
                    "Leyendo página \(pageNumber) de \(document.pageCount)"
                )

                var text = normalized(page.string ?? "")
                if text.count < 40 {
                    text = normalized(try recognizeText(in: page))
                }
                if !text.isEmpty {
                    pages.append(StudySourcePage(pageNumber: pageNumber, text: text))
                }
                await Task.yield()
            }

            guard !pages.isEmpty else { throw PDFStudyError.noReadableText }
            await progress(1, "PDF listo para analizar")

            let rawMetadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let fileTitle = url.deletingPathExtension().lastPathComponent
            let metadataTitle = rawMetadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fileTitle

            return ExtractedStudyDocument(
                title: title,
                fileName: url.lastPathComponent,
                pageCount: document.pageCount,
                pages: pages
            )
        }.value
    }

    private func recognizeText(in page: PDFPage) throws -> String {
        let image = page.thumbnail(of: NSSize(width: 1_800, height: 2_400), for: .mediaBox)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["es-ES", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"(\p{L})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
