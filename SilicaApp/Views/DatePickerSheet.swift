import SwiftUI

struct DatePickerSheet: View {
    let title: String
    @Binding var date: Date
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            DatePicker(AppLanguage.localized(title), selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
                .navigationTitle(AppLanguage.localized(title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppLanguage.localized("完了")) {
                            onDone()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}
