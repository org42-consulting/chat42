import SwiftUI

struct AttachmentChipView: View {
  let name: String
  let type: AttachmentType
  var onRemove: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: type.systemImage)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(name)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 120)
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(0.08), in: Capsule())
  }
}
