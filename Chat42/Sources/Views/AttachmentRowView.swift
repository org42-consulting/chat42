import SwiftUI

struct AttachmentRowView: View {
  @Binding var attachments: [AttachedFile]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(attachments) { file in
          AttachmentChipView(name: file.name, type: file.type) {
            attachments.removeAll { $0.id == file.id }
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}
