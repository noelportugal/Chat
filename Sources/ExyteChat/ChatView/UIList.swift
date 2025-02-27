//
//  UIList.swift
//  
//
//  Created by Alisa Mylnikova on 24.02.2023.
//

import SwiftUI

public extension Notification.Name {
    static let onScrollToBottom = Notification.Name("onScrollToBottom")
}

struct UIList<MessageContent: View>: UIViewRepresentable {

    typealias MessageBuilderClosure = ChatView<MessageContent, EmptyView>.MessageBuilderClosure

    @Environment(\.chatTheme) private var theme

    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var paginationState: PaginationState

    @Binding var isScrolledToBottom: Bool
    @Binding var shouldScrollToTop: () -> ()

    var messageBuilder: MessageBuilderClosure?

    let avatarSize: CGFloat
    let messageUseMarkdown: Bool
    let sections: [MessagesSection]
    let ids: [String]

    @State private var isScrolledToTop = false

    private let updatesQueue = DispatchQueue(label: "updatesQueue")
    @State private var updateSemaphore = DispatchSemaphore(value: 1)
    @State private var tableSemaphore = DispatchSemaphore(value: 0)

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .grouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.transform = CGAffineTransform(rotationAngle: .pi)

        tableView.showsVerticalScrollIndicator = false
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = UITableView.automaticDimension
        tableView.backgroundColor = UIColor(theme.colors.mainBackground)
        tableView.scrollsToTop = false

        NotificationCenter.default.addObserver(forName: .onScrollToBottom, object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                if !context.coordinator.sections.isEmpty {
                    tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .bottom, animated: true)
                }
            }
        }

        DispatchQueue.main.async {
            shouldScrollToTop = {
                tableView.contentOffset = CGPoint(x: 0, y: tableView.contentSize.height - tableView.frame.height)
            }
        }

        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        if context.coordinator.sections == sections {
            return
        }
        updatesQueue.async {
            updateSemaphore.wait()

            if context.coordinator.sections == sections {
                updateSemaphore.signal()
                return
            }

            let prevSections = context.coordinator.sections
            var sectionsWithAppliedDeletes: [MessagesSection] = [] // prev sections + deletes
            var sectionsWithAppliedEdits: [MessagesSection] = [] // prev sections + deletes + edits
            // prev sections + deletes + edits + inserts == section

            //print("1 updateUIView sections:", "\n")
            //print("whole previous:\n", formatSections(prevSections), "\n")
            //print("whole actual sections:\n", formatSections(sections), "\n")

            DispatchQueue.main.async {
                tableView.performBatchUpdates {
                    // step 1
                    // remove sections and rows if needed
                    //print("performBatchUpdates step 2")
                    sectionsWithAppliedDeletes = applyDeletes(tableView: tableView, prevSections: prevSections)
                    //print("whole applied deletes:\n", formatSections(sectionsWithAppliedDeletes), "\n")
                    context.coordinator.sections = sectionsWithAppliedDeletes
                } completion: { _ in
                    tableSemaphore.signal()
                }
            }
            tableSemaphore.wait()

            DispatchQueue.main.async {
                tableView.performBatchUpdates {
                    // step 2
                    // check only sections that are already in the table for existing rows that changed and apply only them to table's dataSource without animation
                    //print("performBatchUpdates step 3")
                    sectionsWithAppliedEdits = applyEdits(tableView: tableView, prevSections: sectionsWithAppliedDeletes)
                    //print("whole applied edits:\n", formatSections(sectionsWithAppliedEdits), "\n")
                    context.coordinator.sections = sectionsWithAppliedEdits
                } completion: { _ in
                    tableSemaphore.signal()
                }
            }
            tableSemaphore.wait()

            if isScrolledToBottom || isScrolledToTop {
                DispatchQueue.main.sync {
                    // step 3
                    // apply the rest of the changes to table's dataSource
                    //print("performBatchUpdates step 4")
                    context.coordinator.sections = sections
                    context.coordinator.ids = ids
                    // insert new rows/sections and remove old ones with animation
                    tableView.beginUpdates()
                    applyInserts(tableView: tableView, prevSections: sectionsWithAppliedEdits)
                    tableView.endUpdates()

                    updateSemaphore.signal()
                }
            } else {
                context.coordinator.ids = ids
                updateSemaphore.signal()
            }
        }
    }

    func applyEdits(tableView: UITableView, prevSections: [MessagesSection]) -> [MessagesSection] {
        var result = [MessagesSection]()
        let prevDates = prevSections.map { $0.date }
        //print("3 applyEdits dates:\n", prevDates, "\n")
        for iPrevDate in 0..<prevDates.count {
            let prevDate = prevDates[iPrevDate]
            guard let section = sections.first(where: { $0.date == prevDate } ),
                  let prevSection = prevSections.first(where: { $0.date == prevDate } ) else { continue }

            var resultRows = [MessageRow]()
            for iPrevRow in 0..<prevSection.rows.count {
                let prevRow = prevSection.rows[iPrevRow]
                guard let row = section.rows.first(where: { $0.message.id == prevRow.message.id } ) else { continue }
                resultRows.append(row)

                if row != prevRow {
                    //print("3 applyEdits different rows. prev:\n", formatRow(prevRow), "\n", formatRow(row))
                    DispatchQueue.main.async {
                        tableView.reloadRows(at: [IndexPath(row: iPrevRow, section: iPrevDate)], with: .none)
                    }
                }
            }
            result.append(MessagesSection(date: prevDate, rows: resultRows))
        }
        return result
    }

    func applyDeletes(tableView: UITableView, prevSections: [MessagesSection]) -> [MessagesSection] {
        var result = prevSections

        // compare sections without comparing messages inside them, just dates
        let dates = sections.map { $0.date }
        let coordinatorDates = prevSections.map { $0.date }
        //print("2 applyDeletes dates prev: \(coordinatorDates)\n\(dates)\n")

        let dif = dates.difference(from: coordinatorDates)
        var indicesToRemove: [Int] = []
        //print(dif, "\n")
        for change in dif {
            switch change {
            case let .remove(offset, _, _):
                //print("2 applyDeletes remove section", offset, "\n")
                indicesToRemove.append(offset)
                tableView.deleteSections([offset], with: .top)
            case .insert(_, _, _):
                break
            }
        }
        indicesToRemove.sorted(by: >).forEach {
            result.remove(at: $0)
        }

        // compare rows for each section
        //print("2 result count", result.count)
        for i in result.indices {
            let section = result[i]
            guard let index = prevSections.firstIndex(where: { $0.date == section.date } ) else { continue }
            let dif = section.rows.difference(from: prevSections[index].rows)
            //print("2 rows dif:\n", dif, "\n")
            indicesToRemove = []

            // animate insertions and removals
            for change in dif {
                switch change {
                case let .remove(offset, _, _):
                    //print("2 remove row offset:", offset, "\n")
                    indicesToRemove.append(offset)
                    tableView.deleteRows(at: [IndexPath(row: offset, section: index)], with: .top)
                case .insert(_, _, _):
                    break
                }
            }
            indicesToRemove.sorted(by: >).forEach {
                result[i].rows.remove(at: $0)
            }
        }
        //print("\n")

        return result
    }

    func applyInserts(tableView: UITableView, prevSections: [MessagesSection]) {
        // compare sections without comparing messages inside them, just dates
        let dates = sections.map { $0.date }
        let coordinatorDates = prevSections.map { $0.date }
        //print("4 applyInserts dates. prev:\n\(coordinatorDates)\n\(dates)\n")

        let dif = dates.difference(from: coordinatorDates)
        //print(dif, "\n")
        for change in dif {
            switch change {
            case .remove(_, _, _):
                break
            case let .insert(offset, _, _):
                //print("4 insert section offset:", offset, "\n")
                tableView.insertSections([offset], with: .top)
            }
        }

        // compare rows for each section
        for section in sections {
            guard let index = prevSections.firstIndex(where: { $0.date == section.date } ) else { continue }
            let dif = section.rows.difference(from: prevSections[index].rows)
            //print("4 rows dif:\n", dif, "\n")

            // animate insertions and removals
            for change in dif {
                switch change {
                case .remove(_, _, _):
                    break
                case let .insert(offset, _, _):
                    //print("4 insert row offset:", offset, "\n")
                    tableView.insertRows(at: [IndexPath(row: offset, section: index)], with: .top)
                }
            }
        }
        //print("\n\n")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, paginationState: paginationState, isScrolledToBottom: $isScrolledToBottom, isScrolledToTop: $isScrolledToTop, messageBuilder: messageBuilder, avatarSize: avatarSize, messageUseMarkdown: messageUseMarkdown, sections: sections, ids: ids, mainBackgroundColor: theme.colors.mainBackground)
    }

    class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {

        @ObservedObject var viewModel: ChatViewModel
        @ObservedObject var paginationState: PaginationState

        @Binding var isScrolledToBottom: Bool
        @Binding var isScrolledToTop: Bool

        var messageBuilder: MessageBuilderClosure?

        let avatarSize: CGFloat
        let messageUseMarkdown: Bool
        var sections: [MessagesSection]
        var ids: [String]

        let mainBackgroundColor: Color

        init(viewModel: ChatViewModel, paginationState: PaginationState, isScrolledToBottom: Binding<Bool>, isScrolledToTop: Binding<Bool>, messageBuilder: MessageBuilderClosure?, avatarSize: CGFloat, messageUseMarkdown: Bool, sections: [MessagesSection], ids: [String], mainBackgroundColor: Color) {
            self.viewModel = viewModel
            self.paginationState = paginationState
            self._isScrolledToBottom = isScrolledToBottom
            self._isScrolledToTop = isScrolledToTop
            self.messageBuilder = messageBuilder
            self.avatarSize = avatarSize
            self.messageUseMarkdown = messageUseMarkdown
            self.sections = sections
            self.ids = ids
            self.mainBackgroundColor = mainBackgroundColor
        }

        func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            sections[section].rows.count
        }

        func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
            let header = UIHostingController(rootView:
                Text(sections[section].formattedDate)
                    .font(.system(size: 11))
                    .rotationEffect(Angle(degrees: 180))
                    .padding(10)
                    .padding(.bottom, 8)
                    .foregroundColor(.gray)
            ).view
            header?.backgroundColor = .clear
            return header
        }

        func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            0.1
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {

            let tableViewCell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            tableViewCell.selectionStyle = .none
            tableViewCell.backgroundColor = UIColor(mainBackgroundColor)

            let row = sections[indexPath.section].rows[indexPath.row]
            tableViewCell.contentConfiguration = UIHostingConfiguration {
                ChatMessageView(viewModel: viewModel, messageBuilder: messageBuilder, row: row, avatarSize: avatarSize, messageUseMarkdown: messageUseMarkdown, isDisplayingMessageMenu: false)
                    .background(MessageMenuPreferenceViewSetter(id: row.id))
                    .rotationEffect(Angle(degrees: 180))
                    .onTapGesture { }
                    .onLongPressGesture {
                        self.viewModel.messageMenuRow = row
                    }
            }
            .minSize(width: 0, height: 0)
            .margins(.all, 0)

            return tableViewCell
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            let row = sections[indexPath.section].rows[indexPath.row]
            paginationState.handle(row.message, ids: ids)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            isScrolledToBottom = scrollView.contentOffset.y <= 0
            isScrolledToTop = scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.frame.height - 1
        }
    }

    func formatRow(_ row: MessageRow) -> String {
        String("id: \(row.id) status: \(row.message.status!) date: \(row.message.createdAt) position: \(row.positionInGroup)")
    }

    func formatSections(_ sections: [MessagesSection]) -> String {
        var res = "{\n"
        for section in sections {
            res += String("\t{\n")
            for row in section.rows {
                res += String("\t\t\(formatRow(row))\n")
            }
            res += String("\t}\n")
        }
        res += String("}")
        return res
    }
}
