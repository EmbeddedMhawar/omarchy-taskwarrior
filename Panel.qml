import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "mhawar.taskwarrior"
  ipcTarget: "taskwarrior"
  manageIpc: false

  readonly property string bridgePath: String(Qt.resolvedUrl("bin/taskwarrior-bridge")).replace(/^file:\/\//, "")
  readonly property string idlePrompt: setting("idlePrompt", "What are you working on?")
  readonly property color idleColor: setting("idleColor", "#ff5555")
  readonly property int idleReminderMinutes: Math.max(1, Number(setting("idleReminderMinutes", 15)))

  property var activeTask: null
  property var lastEntry: null
  property var nextPrayer: null
  property var prayers: ({})
  property bool autoStopAdhan: true
  property var pendingTasks: []
  property var knownProjects: []
  property alias taskInput: taskInputField
  property var allTaskSuggestions: []
  property string inputFilterText: ""
  property int selectedSuggestionIndex: -1
  readonly property var matchingSuggestions: {
    var rawText = root.inputFilterText
    if (rawText.length < 1) return []
    var query = rawText.toLowerCase()
    var matches = []
    var list = root.allTaskSuggestions || []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      var desc = String(s.description || "")
      var proj = String(s.project || "")
      if (desc.toLowerCase().indexOf(query) !== -1 || proj.toLowerCase().indexOf(query) !== -1) {
        matches.push(s)
        if (matches.length >= 5) break
      }
    }
    return matches
  }
  property int totalPending: 0
  property int totalRawPending: 0
  property int todaySeconds: 0
  property int localElapsedSeconds: 0
  property bool isEditingTaskText: false
  property bool isEditingLastTracked: false
  property var editingPendingTaskId: null
  property string activeSelectedPriority: ""
  property int idleMinutesElapsed: 0

  onIsEditingTaskTextChanged: {
    if (isEditingTaskText) {
      root.activeSelectedPriority = root.activeTask ? String(root.activeTask.priority || "") : ""
      Qt.callLater(function() {
        if (typeof taskRenameField !== "undefined" && taskRenameField) {
          taskRenameField.text = root.activeTask ? String(root.activeTask.description || "") : ""
          taskRenameField.forceActiveFocus()
          taskRenameField.selectAll()
        }
        if (typeof activeProjectField !== "undefined" && activeProjectField) {
          activeProjectField.text = root.activeTask ? String(root.activeTask.project || "") : ""
        }
      })
    }
  }

  function priorityColor(p) {
    p = String(p || "").toUpperCase()
    if (p === "H") return "#ff5555"
    if (p === "M") return "#e5c07b"
    if (p === "L") return "#61afef"
    return root.barForeground
  }

  function formatDuration(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var h = Math.floor(sec / 3600)
    var m = Math.floor((sec % 3600) / 60)
    var s = sec % 60
    var mm = (m < 10 ? "0" : "") + m
    var ss = (s < 10 ? "0" : "") + s
    if (h > 0) {
      var hh = (h < 10 ? "0" : "") + h
      return hh + ":" + mm + ":" + ss
    }
    return mm + ":" + ss
  }

  function formatHoursMinutes(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var h = Math.floor(sec / 3600)
    var m = Math.floor((sec % 3600) / 60)
    if (h > 0) return h + "h " + m + "m"
    return m + "m"
  }

  function handleBridgeOutput(raw) {
    if (!raw || raw.trim() === "") return
    try {
      var res = JSON.parse(raw)
      if (res && res.ok) {
        root.activeTask = res.active || null
        root.lastEntry = res.last_entry || null
        root.nextPrayer = res.next_prayer || null
        root.prayers = res.prayers || ({})
        root.autoStopAdhan = (res.auto_stop_adhan !== false)
        root.pendingTasks = res.pending || []
        root.knownProjects = res.projects || []
        root.allTaskSuggestions = res.suggestions || []
        root.totalPending = res.total_pending || 0
        root.totalRawPending = res.total_raw_pending || res.total_pending || 0
        root.todaySeconds = res.today_seconds || 0
        if (root.activeTask) {
          root.localElapsedSeconds = Number(root.activeTask.elapsed_seconds || 0)
          root.idleMinutesElapsed = 0
        } else {
          root.localElapsedSeconds = 0
        }
      }
    } catch (e) {
      // Ignore parse errors from concurrent commands
    }
  }

  function runBridge(args) {
    if (bridgeProc.running) return
    bridgeProc.command = ["python3", root.bridgePath].concat(args)
    bridgeProc.running = true
  }

  function refresh() {
    runBridge(["status"])
  }

  function startTask(idOrUuid) {
    runBridge(["start", String(idOrUuid)])
  }

  function startNewTask(description) {
    runBridge(["start-new", description])
  }

  function selectSuggestion(s, startImmediately) {
    if (!s) return
    var desc = s.description || ""
    var proj = s.project || ""
    var prio = s.priority || ""

    if (startImmediately) {
      var cmd = desc
      if (proj !== "") cmd += " project:" + proj
      if (prio !== "") cmd += " priority:" + prio
      root.startNewTask(cmd)
      if (taskInputField) taskInputField.text = ""
      root.selectedSuggestionIndex = -1
    } else {
      var completedText = desc
      if (proj !== "") completedText += " project:" + proj
      if (prio !== "") completedText += " priority:" + prio
      if (taskInputField) {
        taskInputField.text = completedText
        taskInputField.cursorPosition = completedText.length
      }
      root.selectedSuggestionIndex = -1
    }
  }

  function resumeLastTask() {
    runBridge(["resume"])
  }

  function renameActiveTask(newDescription) {
    runBridge(["rename", newDescription])
  }

  function renameLastTask(newDescription) {
    runBridge(["rename-last", newDescription])
  }

  function renamePendingTask(id, newDescription) {
    runBridge(["rename-task", String(id), newDescription])
  }

  function modifyActiveTask(desc, project, priority) {
    var payload = {
      description: desc,
      project: project || "",
      priority: priority || ""
    }
    runBridge(["modify-active", JSON.stringify(payload)])
  }

  function modifyPendingTask(id, desc, project, priority) {
    var payload = {
      description: desc,
      project: project || "",
      priority: priority || ""
    }
    runBridge(["modify-task", String(id), JSON.stringify(payload)])
  }

  function modifyStartTime(spec) {
    runBridge(["set-start", spec])
  }

  function modifyStopTime(spec) {
    runBridge(["set-stop", spec])
  }

  function stopTask() {
    runBridge(["stop"])
  }

  function stopTaskWithSpec(spec) {
    runBridge(["stop", spec])
  }

  function toggleAdhan() {
    runBridge(["toggle-adhan"])
  }

  function doneTask(idOrUuid) {
    runBridge(["done", String(idOrUuid)])
  }

  function deleteTask(idOrUuid) {
    runBridge(["delete", String(idOrUuid)])
  }

  IpcHandler {
    target: "taskwarrior"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function editTask(id: string): void {
      root.open()
      root.editingPendingTaskId = id
    }
    function editActive(): void {
      root.open()
      root.isEditingTaskText = true
    }
    function setInput(text: string): void {
      root.open()
      if (typeof taskInputField !== "undefined" && taskInputField) {
        taskInputField.text = text
      }
    }
  }

  Process {
    id: bridgeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleBridgeOutput(text)
    }
  }

  Process {
    id: idleNotifyProc
  }

  // Periodic polling
  Timer {
    interval: 3500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Local second-by-second timer increment while active
  Timer {
    interval: 1000
    running: root.activeTask !== null
    repeat: true
    onTriggered: root.localElapsedSeconds += 1
  }

  // 1-minute tick for 15-minute idle reminder notifications
  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    onTriggered: {
      if (root.activeTask !== null) {
        root.idleMinutesElapsed = 0
        return
      }
      root.idleMinutesElapsed += 1
      if (root.idleMinutesElapsed >= root.idleReminderMinutes) {
        root.idleMinutesElapsed = 0
        idleNotifyProc.command = [
          "notify-send",
          "-u", "normal",
          "-a", "Taskwarrior",
          "-i", "alarm",
          "What are you working on?",
          "Timer is idle — don't forget to track your current task!"
        ]
        idleNotifyProc.running = true
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      Qt.callLater(function() {
        if (root.taskInput) {
          root.taskInput.forceActiveFocus()
        }
      })
    } else {
      root.isEditingTaskText = false
      root.isEditingLastTracked = false
      root.editingPendingTaskId = null
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string barLabel: {
    if (root.activeTask) {
      var title = String(root.activeTask.description || "").trim()
      if (title.length > 28) title = title.substring(0, 26) + "…"
      return "󱎫  " + title + "  [" + formatDuration(root.localElapsedSeconds) + "]"
    }
    return "󱎫  " + root.idlePrompt
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: button.vertical ? "󱎫" : root.barLabel
    labelVisible: true
    hasVisualContent: true
    foreground: root.activeTask !== null ? root.barForeground : root.idleColor
    horizontalMargin: 8.5
    verticalPadding: 6
    tooltipText: root.activeTask
      ? "Tracking: " + root.activeTask.description + " (" + formatDuration(root.localElapsedSeconds) + ")\nLeft-click: Manage tasks, start & stop time\nRight-click: Stop tracking"
      : "Taskwarrior: Idle\nLeft-click: Start or pick a task"

    onPressed: function(b) {
      if (b === Qt.RightButton && root.activeTask) {
        root.stopTask()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: taskInputField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (root.taskInput && root.taskInput.activeFocus) || root.isEditingTaskText || root.isEditingLastTracked || (root.editingPendingTaskId !== null)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Top input row: "What are you working on?" + Start button
        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: taskInputField
            width: parent.width - startBtn.width - Style.space(8)
            placeholderText: "What are you working on? (e.g. Task project:Work priority:H)"
            hasCursor: false
            onTextChanged: {
              root.inputFilterText = text.trim()
              root.selectedSuggestionIndex = -1
            }

            Keys.onTabPressed: function(event) {
              if (root.matchingSuggestions.length > 0) {
                var s = root.matchingSuggestions[root.selectedSuggestionIndex >= 0 ? root.selectedSuggestionIndex : 0]
                root.selectSuggestion(s, false)
                event.accepted = true
              }
            }

            Keys.onDownPressed: function(event) {
              if (root.matchingSuggestions.length > 0) {
                root.selectedSuggestionIndex = Math.min(root.matchingSuggestions.length - 1, root.selectedSuggestionIndex + 1)
                event.accepted = true
              }
            }

            Keys.onUpPressed: function(event) {
              if (root.matchingSuggestions.length > 0) {
                root.selectedSuggestionIndex = Math.max(-1, root.selectedSuggestionIndex - 1)
                event.accepted = true
              }
            }

            Keys.onEscapePressed: function(event) {
              root.selectedSuggestionIndex = -1
              taskInputField.text = ""
              event.accepted = true
            }

            onAccepted: {
              if (root.selectedSuggestionIndex >= 0 && root.selectedSuggestionIndex < root.matchingSuggestions.length) {
                root.selectSuggestion(root.matchingSuggestions[root.selectedSuggestionIndex], true)
                text = ""
                root.selectedSuggestionIndex = -1
                return
              }
              var val = text.trim()
              if (val !== "") {
                root.startNewTask(val)
                text = ""
                root.selectedSuggestionIndex = -1
              }
            }
          }

          Button {
            id: startBtn
            text: "Start"
            accent: Commons.Color.accent
            bordered: true
            onClicked: {
              var val = taskInputField.text.trim()
              if (val !== "") {
                root.startNewTask(val)
                taskInputField.text = ""
                root.selectedSuggestionIndex = -1
              }
            }
          }
        }

        // Auto-complete suggestions box (appears as the user types)
        BorderSurface {
          id: suggestionsContainer
          visible: root.inputFilterText.length >= 1 && root.matchingSuggestions.length > 0
          width: parent.width
          implicitHeight: suggestionsCol.implicitHeight + topPadding + bottomPadding
          height: implicitHeight
          color: Style.controlFill(false, false, root.barForeground, Commons.Color.accent)
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("focus", root.barForeground, Commons.Color.accent)
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          leftPadding: Style.space(8)
          rightPadding: Style.space(8)

          Column {
            id: suggestionsCol
            width: parent.width - Style.space(16)
            spacing: Style.space(3)

            Row {
              width: parent.width
              Text {
                text: "SUGGESTIONS (Tab to complete, Click to start)"
                color: Qt.darker(root.barForeground, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
              }
            }

            Repeater {
              model: root.matchingSuggestions
              delegate: Rectangle {
                id: suggRow
                width: suggestionsCol.width
                implicitHeight: Style.space(28)
                height: implicitHeight
                radius: Style.cornerRadius - 2
                color: (suggHover.hovered || root.selectedSuggestionIndex === index)
                  ? Style.controlFill(false, true, root.barForeground, Commons.Color.accent)
                  : "transparent"

                HoverHandler {
                  id: suggHover
                }

                TapHandler {
                  onTapped: root.selectSuggestion(modelData, true)
                }

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)

                  Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: "󰐊"
                      color: Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // Priority
                    Text {
                      visible: Boolean(modelData.priority)
                      text: modelData.priority || ""
                      color: modelData.priority === "H" ? "#ff5555" : (modelData.priority === "M" ? "#e5c07b" : "#61afef")
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // Project
                    Row {
                      visible: Boolean(modelData.project)
                      spacing: Style.space(3)
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        text: "📁"
                        font.pixelSize: Style.font.caption - 1
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Text {
                        text: modelData.project || ""
                        color: "#61afef"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    // Description
                    Text {
                      text: modelData.description || ""
                      color: root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  // Start pill on far right
                  Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(20)
                    width: Style.space(48)
                    radius: Style.cornerRadius - 2
                    color: Commons.Color.accent

                    Text {
                      anchors.centerIn: parent
                      text: "Start"
                      color: Commons.Color.background
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption - 1
                      font.bold: true
                    }
                  }
                }
              }
            }
          }
        }

        // Active task card (visible when a task is currently tracking)
        BorderSurface {
          id: activeCard
          visible: root.activeTask !== null
          width: parent.width
          implicitHeight: activeCol.implicitHeight + topPadding + bottomPadding
          height: implicitHeight
          color: Style.controlFill(false, false, root.barForeground, Commons.Color.accent)
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.barForeground, Commons.Color.accent)
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
          leftPadding: Style.space(12)
          rightPadding: Style.space(12)

          Column {
            id: activeCol
            x: activeCard.leftPadding
            y: activeCard.topPadding
            width: activeCard.width - activeCard.leftPadding - activeCard.rightPadding
            spacing: Style.space(8)

            // Header: Status + live timer + started time
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: "● TRACKING NOW"
                color: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: formatDuration(root.localElapsedSeconds)
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Item { width: Style.space(6); height: 1 }

              Text {
                text: root.activeTask && root.activeTask.start_time_local ? "(Started " + root.activeTask.start_time_local + ")" : ""
                color: Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: root.activeTask && root.activeTask.priority !== ""
                text: root.activeTask ? root.activeTask.priority : ""
                color: root.priorityColor(root.activeTask ? root.activeTask.priority : "")
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: root.activeTask && root.activeTask.project !== ""
                text: root.activeTask ? "󰉋 " + root.activeTask.project : ""
                color: Commons.Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Task description (wraps cleanly)
            Text {
              visible: !root.isEditingTaskText
              width: parent.width
              text: root.activeTask ? String(root.activeTask.description || "") : ""
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              font.bold: true
            }

            // Edit trigger button
            Row {
              visible: !root.isEditingTaskText
              spacing: Style.space(6)

              Button {
                text: "Edit"
                iconText: "󰏫"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  taskRenameField.text = root.activeTask ? String(root.activeTask.description || "") : ""
                  activeProjectField.text = root.activeTask ? String(root.activeTask.project || "") : ""
                  root.activeSelectedPriority = root.activeTask ? String(root.activeTask.priority || "") : ""
                  root.isEditingTaskText = true
                  Qt.callLater(function() {
                    taskRenameField.forceActiveFocus()
                    taskRenameField.selectAll()
                  })
                }
              }
            }

            // Editable details when editing active task
            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.isEditingTaskText

              TextField {
                id: taskRenameField
                width: parent.width
                placeholderText: "Task description"
                verticalPadding: Style.space(3)
                horizontalPadding: Style.space(6)
                font.pixelSize: Style.font.body
                onAccepted: {
                  var desc = taskRenameField.text.trim()
                  var proj = activeProjectField.text.trim()
                  var prio = root.activeSelectedPriority
                  if (desc !== "") {
                    root.modifyActiveTask(desc, proj, prio)
                  }
                  root.isEditingTaskText = false
                }
              }

              // Project & Priority row
              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Project:"
                  color: Qt.darker(root.barForeground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: activeProjectField
                  width: Style.space(110)
                  placeholderText: "e.g. Work"
                  verticalPadding: Style.space(2)
                  horizontalPadding: Style.space(5)
                  font.pixelSize: Style.font.caption
                  onAccepted: {
                    var desc = taskRenameField.text.trim()
                    var proj = activeProjectField.text.trim()
                    var prio = root.activeSelectedPriority
                    if (desc !== "") {
                      root.modifyActiveTask(desc, proj, prio)
                    }
                    root.isEditingTaskText = false
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Priority:"
                  color: Qt.darker(root.barForeground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Row {
                  id: activePriorityButtons
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)

                  Button {
                    text: "None"
                    iconText: selected ? "󰄬" : ""
                    selected: root.activeSelectedPriority === ""
                    bordered: true
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(2)
                    fontSize: Style.font.caption
                    accent: Commons.Color.accent
                    foreground: selected ? Commons.Color.accent : Qt.darker(root.barForeground, 1.4)
                    onClicked: root.activeSelectedPriority = ""
                  }

                  Button {
                    text: "L"
                    iconText: selected ? "󰄬" : ""
                    selected: root.activeSelectedPriority === "L"
                    bordered: true
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(2)
                    fontSize: Style.font.caption
                    accent: "#61afef"
                    foreground: selected ? "#61afef" : Qt.darker(root.barForeground, 1.4)
                    onClicked: root.activeSelectedPriority = (root.activeSelectedPriority === "L" ? "" : "L")
                  }

                  Button {
                    text: "M"
                    iconText: selected ? "󰄬" : ""
                    selected: root.activeSelectedPriority === "M"
                    bordered: true
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(2)
                    fontSize: Style.font.caption
                    accent: "#e5c07b"
                    foreground: selected ? "#e5c07b" : Qt.darker(root.barForeground, 1.4)
                    onClicked: root.activeSelectedPriority = (root.activeSelectedPriority === "M" ? "" : "M")
                  }

                  Button {
                    text: "H"
                    iconText: selected ? "󰄬" : ""
                    selected: root.activeSelectedPriority === "H"
                    bordered: true
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(2)
                    fontSize: Style.font.caption
                    accent: "#ff5555"
                    foreground: selected ? "#ff5555" : Qt.darker(root.barForeground, 1.4)
                    onClicked: root.activeSelectedPriority = (root.activeSelectedPriority === "H" ? "" : "H")
                  }
                }
              }

              // Action buttons row
              Row {
                spacing: Style.space(6)

                Button {
                  text: "Save"
                  iconText: "󰄬"
                  accent: Commons.Color.accent
                  bordered: true
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(3)
                  fontSize: Style.font.caption
                  onClicked: {
                    var desc = taskRenameField.text.trim()
                    var proj = activeProjectField.text.trim()
                    var prio = root.activeSelectedPriority
                    if (desc !== "") {
                      root.modifyActiveTask(desc, proj, prio)
                    }
                    root.isEditingTaskText = false
                  }
                }

                Button {
                  text: "Cancel"
                  iconText: "󰅖"
                  bordered: true
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(3)
                  fontSize: Style.font.caption
                  onClicked: root.isEditingTaskText = false
                }
              }
            }

            // Toggl-style start time adjustments
            Row {
              width: parent.width
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Start:"
                color: Qt.darker(root.barForeground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "+15m"
                tooltipText: "Started 15 mins earlier (+15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStartTime("+15m")
              }

              Button {
                text: "-15m"
                tooltipText: "Started 15 mins later (-15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStartTime("-15m")
              }

              Button {
                text: "+30m"
                tooltipText: "Started 30 mins earlier (+30m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStartTime("+30m")
              }

              TextField {
                id: customStartInput
                width: Style.space(62)
                placeholderText: "HH:MM"
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(4)
                font.pixelSize: Style.font.caption
                onAccepted: {
                  var v = text.trim()
                  if (v !== "") {
                    root.modifyStartTime(v)
                    text = ""
                  }
                }
              }

              Button {
                text: "Set"
                tooltipText: "Apply exact start time (e.g. 08:30)"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  var v = customStartInput.text.trim()
                  if (v !== "") {
                    root.modifyStartTime(v)
                    customStartInput.text = ""
                  }
                }
              }
            }

            // Toggl-style stop time adjustments (Stop at...)
            Row {
              width: parent.width
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Stop at:"
                color: Qt.darker(root.barForeground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "-15m"
                tooltipText: "Stop task with end time 15 mins ago (-15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.stopTaskWithSpec("-15m")
              }

              Button {
                text: "-30m"
                tooltipText: "Stop task with end time 30 mins ago (-30m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.stopTaskWithSpec("-30m")
              }

              TextField {
                id: customStopInput
                width: Style.space(62)
                placeholderText: "HH:MM"
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(4)
                font.pixelSize: Style.font.caption
                onAccepted: {
                  var v = text.trim()
                  if (v !== "") {
                    root.stopTaskWithSpec(v)
                    text = ""
                  }
                }
              }

              Button {
                text: "Stop at"
                tooltipText: "Stop active task at exact time (e.g. 12:20)"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  var v = customStopInput.text.trim()
                  if (v !== "") {
                    root.stopTaskWithSpec(v)
                    customStopInput.text = ""
                  }
                }
              }
            }

            // Main task actions (Stop Now / Done) + Next Adhan indicator
            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Stop Now"
                iconText: "󰓛"
                accent: root.idleColor
                bordered: true
                onClicked: root.stopTask()
              }

              Button {
                text: "Done"
                iconText: "󰄬"
                accent: Commons.Color.accent
                bordered: true
                onClicked: {
                  if (root.activeTask && root.activeTask.id) {
                    root.doneTask(root.activeTask.id)
                  } else {
                    root.stopTask()
                  }
                }
              }

              Item { width: Style.space(4); height: 1 }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.autoStopAdhan && root.nextPrayer !== null
                text: "󰸫 Next: " + (root.nextPrayer ? root.nextPrayer.name + " (" + root.nextPrayer.time + ")" : "")
                color: Qt.darker(root.barForeground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Last Tracked card (visible when idle / no task active)
        BorderSurface {
          id: lastTrackedCard
          visible: root.activeTask === null && root.lastEntry !== null
          width: parent.width
          implicitHeight: lastTrackedCol.implicitHeight + topPadding + bottomPadding
          height: implicitHeight
          color: Style.controlFill(false, false, root.barForeground, Commons.Color.accent)
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.barForeground, Commons.Color.accent)
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
          leftPadding: Style.space(12)
          rightPadding: Style.space(12)

          Column {
            id: lastTrackedCol
            x: lastTrackedCard.leftPadding
            y: lastTrackedCard.topPadding
            width: lastTrackedCard.width - lastTrackedCard.leftPadding - lastTrackedCard.rightPadding
            spacing: Style.space(8)

            // Header row: Status + Duration + Time range + Resume button
            Item {
              width: parent.width
              height: resumeBtn.implicitHeight

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: "󰄬 LAST TRACKED"
                  color: Qt.darker(root.barForeground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.lastEntry ? root.formatHoursMinutes(root.lastEntry.duration_seconds) : ""
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.lastEntry ? "(" + root.lastEntry.start_time_local + " – " + root.lastEntry.end_time_local + ")" : ""
                  color: Qt.darker(root.barForeground, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Button {
                id: resumeBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Resume"
                iconText: "󰐊"
                accent: Commons.Color.accent
                bordered: true
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.resumeLastTask()
              }
            }

            // Description text (when not editing)
            Row {
              visible: !root.isEditingLastTracked
              width: parent.width
              spacing: Style.space(6)

              Text {
                visible: root.lastEntry && Boolean(root.lastEntry.project)
                text: "📁 " + (root.lastEntry ? root.lastEntry.project : "")
                color: "#61afef"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.lastEntry ? String(root.lastEntry.description || "") : ""
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Rename trigger button for last tracked task
            Row {
              visible: !root.isEditingLastTracked
              spacing: Style.space(6)

              Button {
                text: "Rename"
                iconText: "󰏫"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  lastRenameField.text = root.lastEntry ? String(root.lastEntry.description || "") : ""
                  root.isEditingLastTracked = true
                  Qt.callLater(function() {
                    lastRenameField.forceActiveFocus()
                    lastRenameField.selectAll()
                  })
                }
              }
            }

            // Editable description field when renaming last tracked task
            Row {
              width: parent.width
              spacing: Style.space(6)
              visible: root.isEditingLastTracked

              TextField {
                id: lastRenameField
                width: parent.width - saveLastRenameBtn.width - cancelLastRenameBtn.width - Style.space(12)
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(6)
                font.pixelSize: Style.font.caption
                onAccepted: {
                  var val = text.trim()
                  if (val !== "") {
                    root.renameLastTask(val)
                  }
                  root.isEditingLastTracked = false
                }
              }

              Button {
                id: saveLastRenameBtn
                text: "Save"
                iconText: "󰄬"
                accent: Commons.Color.accent
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  var val = lastRenameField.text.trim()
                  if (val !== "") {
                    root.renameLastTask(val)
                  }
                  root.isEditingLastTracked = false
                }
              }

              Button {
                id: cancelLastRenameBtn
                text: "Cancel"
                iconText: "󰅖"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.isEditingLastTracked = false
              }
            }

            // Start time adjustments for last entry
            Row {
              width: parent.width
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Start:"
                color: Qt.darker(root.barForeground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "+15m"
                tooltipText: "Shift start 15 min earlier (+15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStartTime("+15m")
              }

              Button {
                text: "-15m"
                tooltipText: "Shift start 15 min later (-15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStartTime("-15m")
              }

              TextField {
                id: lastStartInput
                width: Style.space(62)
                placeholderText: "HH:MM"
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(4)
                font.pixelSize: Style.font.caption
                onAccepted: {
                  var v = text.trim()
                  if (v !== "") {
                    root.modifyStartTime(v)
                    text = ""
                  }
                }
              }

              Button {
                text: "Set"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  var v = lastStartInput.text.trim()
                  if (v !== "") {
                    root.modifyStartTime(v)
                    lastStartInput.text = ""
                  }
                }
              }
            }

            // Stop time adjustments for last entry
            Row {
              width: parent.width
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Stop: "
                color: Qt.darker(root.barForeground, 1.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Button {
                text: "-15m"
                tooltipText: "End 15 min earlier (-15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStopTime("-15m")
              }

              Button {
                text: "+15m"
                tooltipText: "End 15 min later (+15m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStopTime("+15m")
              }

              Button {
                text: "+30m"
                tooltipText: "End 30 min later (+30m)"
                bordered: true
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: root.modifyStopTime("+30m")
              }

              TextField {
                id: lastStopInput
                width: Style.space(62)
                placeholderText: "HH:MM"
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(4)
                font.pixelSize: Style.font.caption
                onAccepted: {
                  var v = text.trim()
                  if (v !== "") {
                    root.modifyStopTime(v)
                    text = ""
                  }
                }
              }

              Button {
                text: "Set"
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                fontSize: Style.font.caption
                onClicked: {
                  var v = lastStopInput.text.trim()
                  if (v !== "") {
                    root.modifyStopTime(v)
                    lastStopInput.text = ""
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.barForeground
        }

        // Pending tasks header
        PanelSectionHeader {
          width: parent.width
          text: "PENDING TASKS (" + root.totalPending + (root.totalRawPending > root.totalPending ? " · " + root.totalRawPending + " tasks" : "") + ")"
          foreground: root.barForeground
        }

        // Pending tasks list
        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.pendingTasks

            Item {
              id: pendingItem
              required property var modelData
              readonly property bool isExpanded: root.editingPendingTaskId !== null && String(root.editingPendingTaskId) === String(modelData.id)
              width: parent.width
              implicitHeight: isExpanded ? expandedCard.implicitHeight : Style.space(32)
              height: implicitHeight

              onIsExpandedChanged: {
                if (isExpanded) {
                  expandedCard.selectedPriority = modelData.priority || ""
                  if (pendingProjectField) pendingProjectField.text = modelData.project || ""
                  if (pendingEditField) pendingEditField.text = modelData.description || ""
                  Qt.callLater(function() {
                    pendingEditField.forceActiveFocus()
                    pendingEditField.selectAll()
                  })
                }
              }

              // 1. Collapsed view
              Item {
                visible: !pendingItem.isExpanded
                anchors.fill: parent

                MouseArea {
                  id: rowClickArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.editingPendingTaskId = modelData.id
                  }
                }

                Row {
                  id: infoRow
                  anchors.left: parent.left
                  anchors.right: actionButtonsRow.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    id: idText
                    width: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "#" + modelData.id
                    color: Qt.darker(root.barForeground, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  BorderSurface {
                    id: countBadge
                    visible: !!modelData.count && modelData.count > 1
                    anchors.verticalCenter: parent.verticalCenter
                    width: countText.implicitWidth + leftPadding + rightPadding
                    height: countText.implicitHeight + topPadding + bottomPadding
                    color: Style.controlFill(false, false, root.barForeground, Commons.Color.accent)
                    radius: Style.cornerRadius
                    borderSpec: Border.controlSpec("normal", Commons.Color.accent, Commons.Color.accent)
                    leftPadding: Style.space(5)
                    rightPadding: Style.space(5)
                    topPadding: Style.space(1)
                    bottomPadding: Style.space(1)

                    Text {
                      id: countText
                      anchors.centerIn: parent
                      text: String(modelData.count || 1)
                      color: Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    id: prioBadge
                    visible: !!modelData.priority
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.priority || ""
                    color: root.priorityColor(modelData.priority)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    id: projBadge
                    visible: !!modelData.project
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰉋 " + (modelData.project || "")
                    color: Commons.Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    width: Math.max(Style.space(60), infoRow.width - idText.width - Style.space(6) - (countBadge.visible ? countBadge.width + Style.space(6) : 0) - (prioBadge.visible ? prioBadge.implicitWidth + Style.space(6) : 0) - (projBadge.visible ? projBadge.implicitWidth + Style.space(6) : 0))
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.description || ""
                    color: rowClickArea.containsMouse ? Commons.Color.accent : root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }

                Row {
                  id: actionButtonsRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  PanelActionButton {
                    iconText: "󰏫"
                    tooltipText: "View & Edit task"
                    foreground: root.barForeground
                    onClicked: {
                      root.editingPendingTaskId = modelData.id
                    }
                  }

                  PanelActionButton {
                    iconText: "󰐊"
                    tooltipText: "Start tracking"
                    foreground: Commons.Color.accent
                    onClicked: root.startTask(modelData.id)
                  }

                  PanelActionButton {
                    iconText: "󰄬"
                    tooltipText: modelData.count > 1 ? ("Mark all " + modelData.count + " done") : "Mark done"
                    foreground: root.barForeground
                    onClicked: {
                      var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                      root.doneTask(targetIds)
                    }
                  }
                }
              }

              // 2. Expanded view: View & Modify task
              BorderSurface {
                id: expandedCard
                visible: pendingItem.isExpanded
                property string selectedPriority: modelData.priority || ""
                width: parent.width
                implicitHeight: expandedCol.implicitHeight + topPadding + bottomPadding
                height: implicitHeight
                color: Style.controlFill(false, false, root.barForeground, Commons.Color.accent)
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec("normal", Commons.Color.accent, Commons.Color.accent)
                topPadding: Style.space(8)
                bottomPadding: Style.space(8)
                leftPadding: Style.space(10)
                rightPadding: Style.space(10)

                Column {
                  id: expandedCol
                  x: expandedCard.leftPadding
                  y: expandedCard.topPadding
                  width: expandedCard.width - expandedCard.leftPadding - expandedCard.rightPadding
                  spacing: Style.space(8)

                  // Header row
                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: (modelData.count > 1 ? ("TASK #" + modelData.id + " (" + modelData.count + " gathered)") : ("TASK #" + modelData.id))
                      color: Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.urgency !== undefined ? "(Urgency: " + modelData.urgency + ")" : ""
                      color: Qt.darker(root.barForeground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      visible: modelData.count > 1
                      text: "IDs: " + (modelData.ids ? modelData.ids.map(function(x) { return "#" + x }).join(", ") : "")
                      color: Qt.darker(root.barForeground, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Item {
                      width: Math.max(0, parent.width - childrenRect.width - Style.space(40))
                      height: 1
                    }

                    PanelActionButton {
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: "󰅖"
                      tooltipText: "Close"
                      foreground: root.barForeground
                      onClicked: root.editingPendingTaskId = null
                    }
                  }

                  // Editable description input (pre-filled, full text viewable)
                  TextField {
                    id: pendingEditField
                    width: parent.width
                    text: modelData.description || ""
                    font.pixelSize: Style.font.body
                    verticalPadding: Style.space(4)
                    horizontalPadding: Style.space(8)
                    onAccepted: {
                      var desc = text.trim()
                      var proj = pendingProjectField.text.trim()
                      var prio = expandedCard.selectedPriority
                      var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                      if (desc !== "") {
                        root.modifyPendingTask(targetIds, desc, proj, prio)
                      }
                      root.editingPendingTaskId = null
                    }
                  }

                  // Project & Priority row
                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Project:"
                      color: Qt.darker(root.barForeground, 1.3)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    TextField {
                      id: pendingProjectField
                      width: Style.space(110)
                      text: modelData.project || ""
                      placeholderText: "e.g. Work"
                      verticalPadding: Style.space(2)
                      horizontalPadding: Style.space(5)
                      font.pixelSize: Style.font.caption
                      onAccepted: {
                        var desc = pendingEditField.text.trim()
                        var proj = text.trim()
                        var prio = expandedCard.selectedPriority
                        var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                        if (desc !== "") {
                          root.modifyPendingTask(targetIds, desc, proj, prio)
                        }
                        root.editingPendingTaskId = null
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Priority:"
                      color: Qt.darker(root.barForeground, 1.3)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Row {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Button {
                        text: "None"
                        iconText: selected ? "󰄬" : ""
                        selected: expandedCard.selectedPriority === ""
                        bordered: true
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(2)
                        fontSize: Style.font.caption
                        accent: Commons.Color.accent
                        foreground: selected ? Commons.Color.accent : Qt.darker(root.barForeground, 1.4)
                        onClicked: expandedCard.selectedPriority = ""
                      }

                      Button {
                        text: "L"
                        iconText: selected ? "󰄬" : ""
                        selected: expandedCard.selectedPriority === "L"
                        bordered: true
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(2)
                        fontSize: Style.font.caption
                        accent: "#61afef"
                        foreground: selected ? "#61afef" : Qt.darker(root.barForeground, 1.4)
                        onClicked: expandedCard.selectedPriority = (expandedCard.selectedPriority === "L" ? "" : "L")
                      }

                      Button {
                        text: "M"
                        iconText: selected ? "󰄬" : ""
                        selected: expandedCard.selectedPriority === "M"
                        bordered: true
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(2)
                        fontSize: Style.font.caption
                        accent: "#e5c07b"
                        foreground: selected ? "#e5c07b" : Qt.darker(root.barForeground, 1.4)
                        onClicked: expandedCard.selectedPriority = (expandedCard.selectedPriority === "M" ? "" : "M")
                      }

                      Button {
                        text: "H"
                        iconText: selected ? "󰄬" : ""
                        selected: expandedCard.selectedPriority === "H"
                        bordered: true
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(2)
                        fontSize: Style.font.caption
                        accent: "#ff5555"
                        foreground: selected ? "#ff5555" : Qt.darker(root.barForeground, 1.4)
                        onClicked: expandedCard.selectedPriority = (expandedCard.selectedPriority === "H" ? "" : "H")
                      }
                    }
                  }

                  // Action buttons
                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Button {
                      text: "Save"
                      iconText: "󰄬"
                      accent: Commons.Color.accent
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      fontSize: Style.font.caption
                      onClicked: {
                        var desc = pendingEditField.text.trim()
                        var proj = pendingProjectField.text.trim()
                        var prio = expandedCard.selectedPriority
                        var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                        if (desc !== "") {
                          root.modifyPendingTask(targetIds, desc, proj, prio)
                        }
                        root.editingPendingTaskId = null
                      }
                    }

                    Button {
                      text: "Cancel"
                      iconText: "󰅖"
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      fontSize: Style.font.caption
                      onClicked: root.editingPendingTaskId = null
                    }

                    Button {
                      text: "Start"
                      iconText: "󰐊"
                      accent: Commons.Color.accent
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      fontSize: Style.font.caption
                      onClicked: {
                        var desc = pendingEditField.text.trim()
                        var proj = pendingProjectField.text.trim()
                        var prio = expandedCard.selectedPriority
                        var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                        if (desc !== "" && (desc !== (modelData.description || "") || proj !== (modelData.project || "") || prio !== (modelData.priority || ""))) {
                          root.modifyPendingTask(targetIds, desc, proj, prio)
                        }
                        root.startTask(modelData.id)
                        root.editingPendingTaskId = null
                      }
                    }

                    Button {
                      text: modelData.count > 1 ? ("Done (" + modelData.count + ")") : "Done"
                      iconText: "󰄬"
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      fontSize: Style.font.caption
                      onClicked: {
                        var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                        root.doneTask(targetIds)
                        root.editingPendingTaskId = null
                      }
                    }

                    Button {
                      text: modelData.count > 1 ? ("Delete (" + modelData.count + ")") : "Delete"
                      iconText: "󰆴"
                      accent: root.idleColor
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      fontSize: Style.font.caption
                      onClicked: {
                        var targetIds = modelData.ids ? modelData.ids.join(",") : String(modelData.id)
                        root.deleteTask(targetIds)
                        root.editingPendingTaskId = null
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.pendingTasks.length === 0
            text: "No pending tasks in Taskwarrior"
            color: Qt.darker(root.barForeground, 1.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.barForeground
        }

        // Footer: Today total tracked + Adhan toggle + Terminal launch button
        Item {
          width: parent.width
          height: Math.max(tasksCliBtn.implicitHeight, adhanBtn.implicitHeight)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󱎫 Today: " + root.formatHoursMinutes(root.todaySeconds)
            color: Qt.darker(root.barForeground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              id: adhanBtn
              text: root.autoStopAdhan
                ? (root.nextPrayer ? "󰸫 " + root.nextPrayer.name + " " + root.nextPrayer.time : "󰸫 Adhan ON")
                : "󰸫 Adhan OFF"
              tooltipText: root.autoStopAdhan
                ? "Adhan auto-stop is ACTIVE.\nTasks automatically stop at prayer times.\nClick to disable."
                : "Adhan auto-stop is OFF.\nClick to enable."
              accent: root.autoStopAdhan ? Commons.Color.accent : root.barForeground
              bordered: true
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              fontSize: Style.font.caption
              onClicked: root.toggleAdhan()
            }

            Button {
              id: tasksCliBtn
              text: "Tasks CLI"
              iconText: "󰆍"
              bordered: true
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              fontSize: Style.font.caption
              onClicked: {
                root.close()
                if (root.bar) root.bar.run("omarchy-launch-or-focus-tui task")
              }
            }
          }
        }
      }
    }
  }
}
