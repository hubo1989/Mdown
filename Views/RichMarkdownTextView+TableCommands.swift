import AppKit

// MARK: - T16 行列命令与右键菜单(RichMarkdownTextView 扩展)
//
// 模型计划(Business/MarkdownTableModel)→ applyStructurePatches 的
// source 事务:单条历史、单步撤销、失败闭口。命令统一读 caret——右键
// 落格时 menu(for:) 先把 caret 设到点击处(Typora 语义),无第二坐标源。

extension RichMarkdownTextView {

    /// 命令目标 = caret 所在 cell(模型 + 行列号)。
    struct TableCommandTarget {
        let model: MarkdownTableModel
        let row: Int
        let column: Int
    }

    /// 应用表格计划。caret 默认落 `plan.caretAfterUTF16`(插行落新行
    /// 首格、删/移后落安全存活位——增删移后 pre-edit 偏移会错位);
    /// `keepCaretAt` 仅在调用方显式指定时覆盖。
    func applyTablePlan(
        _ plan: MarkdownTablePlan, _ name: String, keepCaretAt caret: Int? = nil
    ) -> Bool {
        applyStructurePatches(
            plan.patches, name: name,
            restoreSourceCaret: caret ?? plan.caretAfterUTF16, origin: .structure)
    }

    func tableCommandTarget() -> TableCommandTarget? {
        guard let model = tableModelAtCaret(),
            let pos = tablePosition(model, caret: sourceCaret())
        else { return nil }
        return TableCommandTarget(model: model, row: pos.row, column: pos.column)
    }

    @discardableResult
    func insertTableRowBelowAtCaret() -> Bool {
        guard let t = tableCommandTarget(),
            let plan = t.model.insertRow(after: t.row, columnCount: t.model.columnCount)
        else { return false }
        return applyTablePlan(plan, "table-insert-row")
    }

    @discardableResult
    func deleteTableRowAtCaret() -> Bool {
        guard let t = tableCommandTarget(), let plan = t.model.deleteRow(t.row) else { return false }
        return applyTablePlan(plan, "table-delete-row")
    }

    @discardableResult
    func insertTableColumnAtCaret() -> Bool {
        guard let t = tableCommandTarget(), let plan = t.model.insertColumn(before: t.column) else {
            return false
        }
        return applyTablePlan(plan, "table-insert-column")
    }

    @discardableResult
    func deleteTableColumnAtCaret() -> Bool {
        guard let t = tableCommandTarget(), let plan = t.model.deleteColumn(t.column) else {
            return false
        }
        return applyTablePlan(plan, "table-delete-column")
    }

    @discardableResult
    func moveTableRowUpAtCaret() -> Bool {
        guard let t = tableCommandTarget(), let plan = t.model.moveRow(from: t.row, to: t.row - 1)
        else { return false }
        return applyTablePlan(plan, "table-move-row-up")
    }

    @discardableResult
    func moveTableRowDownAtCaret() -> Bool {
        guard let t = tableCommandTarget(), let plan = t.model.moveRow(from: t.row, to: t.row + 1)
        else { return false }
        return applyTablePlan(plan, "table-move-row-down")
    }

    @discardableResult
    func moveTableColumnLeftAtCaret() -> Bool {
        guard let t = tableCommandTarget(),
            let plan = t.model.moveColumn(from: t.column, to: t.column - 1)
        else { return false }
        return applyTablePlan(plan, "table-move-column-left")
    }

    @discardableResult
    func moveTableColumnRightAtCaret() -> Bool {
        guard let t = tableCommandTarget(),
            let plan = t.model.moveColumn(from: t.column, to: t.column + 1)
        else { return false }
        return applyTablePlan(plan, "table-move-column-right")
    }

    @discardableResult
    func setTableAlignmentAtCaret(_ alignment: MarkdownTableAlignment) -> Bool {
        guard let t = tableCommandTarget(),
            let plan = t.model.setAlignment(t.column, alignment)
        else { return false }
        return applyTablePlan(plan, "table-set-alignment")
    }

    // MARK: - 右键菜单(T16 入口)

    /// 右键落格时把 caret 移到点击处并追加行列命令项。
    func appendTableMenuItems(to menu: NSMenu, for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(for: point)
        guard index != NSNotFound, index <= (string as NSString).length else { return }
        setSelectedRange(NSRange(location: index, length: 0))
        guard tableCommandTarget() != nil else { return }

        menu.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("Add Row Below", #selector(tableInsertRowBelow(_:))),
            ("Delete Row", #selector(tableDeleteRow(_:))),
            ("Insert Column", #selector(tableInsertColumn(_:))),
            ("Delete Column", #selector(tableDeleteColumn(_:))),
            ("Move Row Up", #selector(tableMoveRowUp(_:))),
            ("Move Row Down", #selector(tableMoveRowDown(_:))),
            ("Move Column Left", #selector(tableMoveColumnLeft(_:))),
            ("Move Column Right", #selector(tableMoveColumnRight(_:))),
        ]
        for (title, action) in actions {
            let item = NSMenuItem(title: I18n.str(title), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let align = NSMenuItem(title: I18n.str("Align Column"), action: nil, keyEquivalent: "")
        let alignMenu = NSMenu()
        let alignments: [(String, MarkdownTableAlignment)] = [
            (I18n.str("No Alignment"), .none), (I18n.str("Align Left"), .left),
            (I18n.str("Align Center"), .center), (I18n.str("Align Right"), .right),
        ]
        for (title, kind) in alignments {
            let item = NSMenuItem(
                title: title, action: #selector(tableAlign(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            alignMenu.addItem(item)
        }
        align.submenu = alignMenu
        menu.addItem(align)
    }

    @objc func tableInsertRowBelow(_ sender: Any?) { insertTableRowBelowAtCaret() }
    @objc func tableDeleteRow(_ sender: Any?) { deleteTableRowAtCaret() }
    @objc func tableInsertColumn(_ sender: Any?) { insertTableColumnAtCaret() }
    @objc func tableDeleteColumn(_ sender: Any?) { deleteTableColumnAtCaret() }
    @objc func tableMoveRowUp(_ sender: Any?) { moveTableRowUpAtCaret() }
    @objc func tableMoveRowDown(_ sender: Any?) { moveTableRowDownAtCaret() }
    @objc func tableMoveColumnLeft(_ sender: Any?) { moveTableColumnLeftAtCaret() }
    @objc func tableMoveColumnRight(_ sender: Any?) { moveTableColumnRightAtCaret() }
    @objc func tableAlign(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let kind = MarkdownTableAlignment(rawValue: raw)
        else { return }
        setTableAlignmentAtCaret(kind)
    }
}
