import AppKit
import SwiftUI

@MainActor
final class CandidatePanel: NSPanel {
    private var host: NSHostingView<CandidateView>?
    private var revision = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        isFloatingPanel = true; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        level = .popUpMenu
    }
    func show(session: CompositionSession, anchor: NSRect, expand: (()->Void)? = nil, ask: (()->Void)? = nil, settings: @escaping ()->Void) {
        guard !session.markedText.isEmpty || session.translation != nil else { orderOut(nil); return }
        revision += 1
        let screen = NSScreen.screens.first(where:{$0.frame.intersects(anchor)}) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        let composition = CompositionDisplay(session:session)
        let controlsWidth = ceil((session.asciiMode ? "EN" : session.pinyinLayout.shortName).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width) + (session.isInEditor ? 28 : 85) + (expand == nil ? 0 : 28) + (ask == nil ? 0 : 28)
        let candidateWidth = session.candidates.reduce(CGFloat(54)) { $0 + $1.size(withAttributes:[.font:NSFont.systemFont(ofSize:15)]).width + 35 }
        let width = min(max(320,candidateWidth,composition.text.size().width+controlsWidth+38),min(600,visible.width-12))
        let compositionWidth = max(40,width-controlsWidth-38)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for:NSFont.systemFont(ofSize:13)))
        let compositionHeight = min(4*lineHeight,max(18,ceil(composition.text.boundingRect(with:NSSize(width:compositionWidth-12,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).height)))
        // Measure wrapped content at its actual display width before capping the
        // viewport. Measuring an unconstrained row and narrowing it afterwards
        // clips both text and the window at the screen edge.
        let measuring = NSHostingView(rootView:CandidateList(session:session,revision:revision).frame(width:width-14))
        let naturalHeight = session.candidates.isEmpty ? 0 : ceil(measuring.fittingSize.height)
        let errorHeight = session.errorMessage.map { ceil(($0 as NSString).boundingRect(with:NSSize(width:width-26,height:.greatestFiniteMagnitude),options:.usesLineFragmentOrigin,attributes:[.font:NSFont.systemFont(ofSize:11)]).height)+6 } ?? 0
        let chromeHeight = compositionHeight+19 + (session.buffersText ? 40 : 0) + (session.isTranslating ? 28 : 0) + errorHeight
        let candidateHeight = min(naturalHeight,max(0,min(420,visible.height-12)-chromeHeight-7))
        let root = CandidateView(session:session,revision:revision,composition:composition,compositionWidth:compositionWidth,compositionHeight:compositionHeight,controlsWidth:controlsWidth,candidateHeight:candidateHeight,expand:expand,ask:ask,settings:settings)
        if let host { host.rootView = root }
        else { let view = NSHostingView(rootView:root); host = view; contentView = view }
        let height = ceil(host!.fittingSize.height)
        setFrame(Self.placement(size:NSSize(width:width,height:height),anchor:anchor,visible:visible),display:true)
        orderFrontRegardless()
    }
    static func placement(size:NSSize,anchor:NSRect,visible:NSRect) -> NSRect {
        let width = min(size.width,visible.width-12), height = min(size.height,visible.height-12)
        var x = anchor.minX, y = anchor.minY-height-5
        if anchor == .zero { x = visible.midX-width/2; y = visible.midY-height/2 }
        else if y < visible.minY+6 { y = anchor.maxY+5 }
        x = max(visible.minX+6,min(x,visible.maxX-width-6))
        y = max(visible.minY+6,min(y,visible.maxY-height-6))
        return NSRect(x:x,y:y,width:width,height:height)
    }
}

@MainActor
private struct CompositionDisplay {
    let text: NSAttributedString
    let caret: Int
    init(session:CompositionSession) {
        let state = session.snapshot
        let value = NSMutableAttributedString(string:session.isInEditor ? state.preedit : session.markedText,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
        let active = NSRange(location:(session.isInEditor ? 0 : session.pendingTextStart)+state.selectionStart,length:state.selectionEnd-state.selectionStart)
        if active.length > 0 && NSMaxRange(active) <= value.length { value.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:active) }
        caret = min(max(session.isInEditor ? state.caret : session.markedCaret,0),value.length)
        value.insert(NSAttributedString(string:"│",attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.systemPurple]),at:caret)
        text = value
    }
}

// The complete composition remains available by scrolling. Keep the actual
// editing caret visible, including when moving back into a long pinyin string.
private struct CompositionTextView: NSViewRepresentable {
    let display: CompositionDisplay
    let width: CGFloat
    let height: CGFloat
    final class Coordinator { var text: NSAttributedString?; var caret = -1; var width:CGFloat = 0; var revision = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
        text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.setAccessibilityLabel("待确认的输入")
        scroll.documentView = text
        scroll.identifier = NSUserInterfaceItemIdentifier("composition-scroll")
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let text = scroll.documentView as! NSTextView
        let changed = context.coordinator.text?.isEqual(to:display.text) != true || context.coordinator.caret != display.caret || context.coordinator.width != width
        scroll.frame.size = NSSize(width:width,height:height)
        text.textContainer?.containerSize = NSSize(width:max(1,width-12),height:.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textStorage?.setAttributedString(display.text)
        text.layoutManager?.ensureLayout(for:text.textContainer!)
        let used = text.layoutManager!.usedRect(for:text.textContainer!)
        text.frame = NSRect(x:0,y:0,width:width,height:max(height,ceil(used.height)))
        let coordinator = context.coordinator
        coordinator.text = display.text; coordinator.caret = display.caret; coordinator.width = width
        if changed {
            coordinator.revision += 1
            let revision = coordinator.revision
            // SwiftUI finishes sizing the clip view after updateNSView. Reveal
            // the caret then, rather than scrolling against the previous frame.
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, coordinator.revision == revision else { return }
                scroll.layoutSubtreeIfNeeded()
                let layout = text.layoutManager!, container = text.textContainer!
                layout.ensureLayout(for:container)
                let glyph = layout.glyphRange(forCharacterRange:NSRange(location:coordinator.caret,length:1),actualCharacterRange:nil)
                let rect = layout.boundingRect(forGlyphRange:glyph,in:container)
                let clip = scroll.contentView, viewport = clip.bounds
                var y = viewport.minY
                if rect.minY < viewport.minY { y = rect.minY }
                else if rect.maxY > viewport.maxY { y = rect.maxY-viewport.height }
                y = max(0,min(y,text.frame.height-viewport.height))
                clip.scroll(to:NSPoint(x:0,y:y)); scroll.reflectScrolledClipView(clip)
            }
        }
    }
}

// Short words share a row. A long candidate gets the available width and wraps
// in full; subsequent candidates flow onto the next row, retaining their IDs.
struct CandidateFlowLayout: Layout {
    static func frames(sizes:[CGSize],width:CGFloat,spacing:CGFloat = 4) -> [CGRect] {
        var result:[CGRect] = [], x:CGFloat = 0, y:CGFloat = 0, rowHeight:CGFloat = 0
        for size in sizes {
            if x > 0 && x+size.width > width { x = 0; y += rowHeight+spacing; rowHeight = 0 }
            result.append(CGRect(origin:CGPoint(x:x,y:y),size:size))
            x += size.width+spacing; rowHeight = max(rowHeight,size.height)
        }
        return result
    }
    private func frames(_ subviews:Subviews,width:CGFloat) -> [CGRect] {
        Self.frames(sizes:subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            return view.sizeThatFits(ProposedViewSize(width:min(width,ideal.width),height:nil))
        },width:width)
    }
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let width = proposal.width ?? 586
        let rects = frames(subviews,width:width)
        return CGSize(width:width,height:rects.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        for (view,rect) in zip(subviews,frames(subviews,width:bounds.width)) {
            view.place(at:CGPoint(x:bounds.minX+rect.minX,y:bounds.minY+rect.minY),anchor:.topLeading,proposal:ProposedViewSize(rect.size))
        }
    }
}

@MainActor
private struct CandidateList: View {
    let session:CompositionSession
    // CompositionSession is a mutable reference, so explicitly invalidate the
    // view after each update while retaining the enclosing scroll position.
    let revision:Int
    private let purple = Color(red:0.47,green:0.34,blue:0.76)
    var body: some View {
        if session.translation != nil || session.isTranslating || session.errorMessage != nil {
            VStack(alignment:.leading,spacing:3) {
                ForEach(Array(session.candidates.enumerated()),id:\.offset) { index,text in candidate(index,text,large:true).id(index) }
            }
        } else {
            CandidateFlowLayout {
                ForEach(Array(session.candidates.prefix(5).enumerated()),id:\.offset) { index,text in candidate(index,text,large:false).id(index) }
                if session.snapshot.page > 0 || !session.snapshot.lastPage {
                    HStack(spacing:8) {
                        if session.snapshot.page > 0 { Button { session.handle(key:0xff55) } label:{Image(systemName:"chevron.left")}.help("上一页（- / Page Up）") }
                        if !session.snapshot.lastPage { Button { session.handle(key:0xff56) } label:{Image(systemName:"chevron.right")}.help("下一页（= / + / Page Down）") }
                    }.buttonStyle(.plain).font(.system(size:11)).padding(.vertical,8).padding(.horizontal,4)
                }
            }
        }
    }
    private func candidate(_ index:Int,_ text:String,large:Bool) -> some View {
        Button { session.choose(index) } label: {
            HStack(alignment:.firstTextBaseline,spacing:7) {
                Text("\(index+1)").font(.system(size:10)).foregroundStyle(.secondary).fixedSize()
                Text(text).font(.system(size:large ? 13 : 15)).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                if large { Spacer(minLength:0) }
            }.padding(.horizontal,8).padding(.vertical,large ? 8 : 6)
                .foregroundStyle(index == session.highlighted ? purple : Color.primary)
                .background(index == session.highlighted ? purple.opacity(0.1) : .clear)
                .clipShape(RoundedRectangle(cornerRadius:5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(text).accessibilityLabel("\(index+1) \(text)")
    }
}

@MainActor
private struct CandidateView: View {
    let session: CompositionSession
    let revision:Int
    let composition: CompositionDisplay
    let compositionWidth: CGFloat
    let compositionHeight: CGFloat
    let controlsWidth: CGFloat
    let candidateHeight: CGFloat
    var expand: (()->Void)?
    var ask: (()->Void)?
    var settings: ()->Void
    private let purple = Color(red:0.47,green:0.34,blue:0.76)
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.top,spacing:12) {
                CompositionTextView(display:composition,width:compositionWidth,height:compositionHeight)
                    .frame(width:compositionWidth,height:compositionHeight)
                    .help("← → 选择候选 · - / + 翻页 · 首项再按 ← 编辑拼音 · 长输入可滚动查看")
                HStack(spacing:12) {
                    Button { session.setASCIIMode(!session.asciiMode) } label: {
                        Text(session.asciiMode ? "EN" : session.pinyinLayout.shortName).font(.system(size:11)).foregroundStyle(.secondary)
                    }.help(session.pendingPinyinLayout.map { "选完当前拼音后切换为\($0.name)" } ?? "\(session.pinyinLayout.name) · Shift 切换中英文")
                    if !session.isInEditor { Button { session.setTranslateEnabled(!session.translateEnabled) } label: {
                        HStack(spacing:5) { Text("译英"); Image(systemName:session.translateEnabled ? "checkmark.circle.fill" : "circle") }
                            .font(.system(size:11)).foregroundStyle(session.translateEnabled ? purple : .secondary)
                    } }
                    if let ask { Button(action:ask) { Image(systemName:"bubble.left.and.text.bubble.right").font(.system(size:12)).foregroundStyle(purple) }.help("问 AI：用已确认的草稿提问") }
                    if let expand { Button(action:expand) { Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:12)).foregroundStyle(purple) }.help("放大到临时编辑区") }
                    Button(action:settings) { Image(systemName:"slider.horizontal.3").foregroundStyle(.secondary).font(.system(size:12)) }.help("输入与翻译设置")
                }.buttonStyle(.plain).fixedSize().frame(width:controlsWidth,alignment:.trailing)
            }.padding(.horizontal,13).padding(.top,11).padding(.bottom,8)
            if session.isTranslating { HStack { ProgressView().controlSize(.small); Text("正在翻译整句…").font(.system(size:12)); Spacer() }.padding(.horizontal,13).padding(.bottom,8) }
            if let error = session.errorMessage { Text(error).font(.system(size:11)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true).padding(.horizontal,13).padding(.bottom,6) }
            if !session.candidates.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        CandidateList(session:session,revision:revision)
                    }.frame(height:candidateHeight)
                        .onAppear { proxy.scrollTo(session.highlighted,anchor:.top) }
                        .onChange(of:selectionID) { _ in proxy.scrollTo(session.highlighted,anchor:.top) }
                }.padding(.horizontal,7).padding(.bottom,7)
            }
            if session.buffersText {
                Divider().opacity(0.6)
                HStack {
                    Text(session.isInEditor ? "空格选词 · Enter 原样输入 · Shift 中/英" : session.translation != nil ? "Enter 英文上屏 · Esc 修改中文" : !session.snapshot.input.isEmpty ? "空格选词 · Enter 原样输入" : session.asciiMode ? "英文输入 · Shift 切回中文" : "Enter 中文上屏 · Shift 中/英").font(.system(size:10)).foregroundStyle(.secondary)
                    Spacer()
                    if !session.isInEditor && session.translation == nil && !session.isTranslating {
                        Button { session.requestTranslation() } label: {
                            Text(session.hasPendingInput ? "先完成选词" : "翻译整句 ⌃↵")
                                .font(.system(size:11)).foregroundStyle(session.canRequestTranslation ? purple : .secondary)
                        }.buttonStyle(.plain).disabled(!session.canRequestTranslation)
                            .help(session.hasPendingInput ? "还有未确认的输入，请先完成选词再按 Ctrl + Enter" : "翻译已确认的整段内容")
                    }
                }.padding(.horizontal,13).padding(.vertical,9)
            }
        }
        .frame(width:compositionWidth+controlsWidth+38)
        .background(Color(nsColor:.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).stroke(Color(nsColor:.separatorColor).opacity(0.55),lineWidth:1))
        .colorScheme(.light)
    }
    private var selectionID: String {
        "\(session.snapshot.page):\(session.highlighted):" + (session.candidates.indices.contains(session.highlighted) ? session.candidates[session.highlighted] : "")
    }
}
