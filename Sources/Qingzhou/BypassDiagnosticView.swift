import SwiftUI
import QingzhouKit

struct BypassDiagnosticView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model:AppModel
    var body:some View {
        VStack {TargetPathPanel(model:model);HStack {Spacer();Button("关闭"){dismiss()}}}
            .padding(24).frame(width:800,height:570)
    }
}
