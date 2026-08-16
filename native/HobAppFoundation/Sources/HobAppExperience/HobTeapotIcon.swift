// SPDX-License-Identifier: MIT
import SwiftUI

public struct HobTeapotIcon: View {
    private let filled: Bool

    public init(filled: Bool = true) {
        self.filled = filled
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Ellipse()
                    .trim(from: 0.17, to: 0.83)
                    .stroke(
                        style: StrokeStyle(
                            lineWidth: max(1.2, width * 0.10),
                            lineCap: .round
                        )
                    )
                    .frame(width: width * 0.38, height: height * 0.58)
                    .offset(x: width * 0.31, y: height * 0.10)
                if filled {
                    HobTeapotBody().fill()
                } else {
                    HobTeapotBody().stroke(
                        style: StrokeStyle(
                            lineWidth: max(1.1, width * 0.085),
                            lineJoin: .round
                        )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HobTeapotBody: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.27, y: height * 0.40))
        path.addCurve(
            to: CGPoint(x: width * 0.35, y: height * 0.91),
            control1: CGPoint(x: width * 0.18, y: height * 0.54),
            control2: CGPoint(x: width * 0.20, y: height * 0.82)
        )
        path.addLine(to: CGPoint(x: width * 0.68, y: height * 0.91))
        path.addCurve(
            to: CGPoint(x: width * 0.76, y: height * 0.40),
            control1: CGPoint(x: width * 0.83, y: height * 0.82),
            control2: CGPoint(x: width * 0.85, y: height * 0.54)
        )
        path.closeSubpath()

        path.move(to: CGPoint(x: width * 0.29, y: height * 0.45))
        path.addLine(to: CGPoint(x: width * 0.08, y: height * 0.27))
        path.addQuadCurve(
            to: CGPoint(x: width * 0.24, y: height * 0.65),
            control: CGPoint(x: width * 0.01, y: height * 0.40)
        )
        path.closeSubpath()

        path.addRoundedRect(
            in: CGRect(
                x: width * 0.34,
                y: height * 0.25,
                width: width * 0.36,
                height: height * 0.13
            ),
            cornerSize: CGSize(width: width * 0.05, height: width * 0.05)
        )
        path.addRoundedRect(
            in: CGRect(
                x: width * 0.45,
                y: height * 0.14,
                width: width * 0.14,
                height: height * 0.11
            ),
            cornerSize: CGSize(width: width * 0.04, height: width * 0.04)
        )
        return path
    }
}
