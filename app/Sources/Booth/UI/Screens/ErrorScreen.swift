import SwiftUI

/// A file that can't be used: what is wrong, and that nothing was changed.
struct ErrorScreen: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(model.errorTitle ?? "")
            Paragraph(model.errorBody ?? "")
                .padding(.top, 3)
        }
    }
}

struct ErrorFooter: View {
    let model: AppModel

    var body: some View {
        Button("Choose another", action: model.chooseAnother)
            .buttonStyle(PillButtonStyle())
            .footerInset(.pill)
    }
}
