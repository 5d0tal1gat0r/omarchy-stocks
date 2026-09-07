import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// State owner for the Stocks widget: fetches quotes and chart series, and
// renders the click-to-open panel. BarWidget.qml loads this and mirrors
// `tapeItems` / `label` into the bar (same split as omarchy.weather).
Panel {
  id: root
  moduleName: "io.github.5d0tal1gat0r.stocks"
  // The bar entry (BarWidget.qml) owns the IPC target; see its IpcHandler.
  manageIpc: false

  property var anchorItem: null
  // The bar identifies a panel by the widget mounted in its slot, not by this
  // nested item, so popout switching and the open-panel indicator use it.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings (inline on this widget's shell.json entry).
  readonly property var symbols: Model.normalizeSymbols(setting("symbols", null))
  readonly property string symbolsKey: symbols.join(",")
  readonly property int refreshMinutes: Model.refreshMinutes(setting("refreshMinutes", 5))
  readonly property bool compact: setting("compact", false) === true || String(setting("compact", false)) === "true"
  readonly property string activeRange: Model.chartRange(setting("chartRange", "1d"))
  readonly property string displayCurrency: Model.normalizeCurrency(setting("currency", ""))
  readonly property var currencies: Model.normalizeCurrencies(setting("currencies", null))
  readonly property string upColorSetting: Model.normalizeColor(setting("upColor", ""))
  readonly property string downColorSetting: Model.normalizeColor(setting("downColor", ""))

  // ---- Quote state. `quotes` keeps the last good result across failures so
  //      stale-but-useful numbers stay visible; `fetchError` explains why.
  property var quotes: []
  property string fetchError: ""
  property var lastUpdated: null
  property int retries: 0
  property int selectedIndex: 0

  // ---- Dynamic screen state. Screen.js evaluates the current S&P 500 once
  //      per day and returns every match from its on-disk cache.
  property int activeTab: 0
  property var screenStocks: []
  property string screenFetchError: ""
  property string screenFetchWarning: ""
  property var screenLastUpdated: null
  property string screenAsOf: ""
  property var screenCoverage: ({})
  property bool screenLoading: true
  property bool screenLoaded: false
  property string lastScreenNotification: ""
  readonly property string screenScriptPath: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/" + moduleName + "/Screen.js"
  property string screenSortKey: ""
  property int screenSortDirection: 1
  readonly property var screenRows: Model.screenRows(screenStocks, [], {})
  readonly property var sortedScreenRows: Model.sortScreenRows(screenRows, screenSortKey, screenSortDirection)

  // ---- Chart-series cache for the active range when it is not 1d (the 1d
  //      series rides along with every quote fetch).
  property var chartSeries: ({})
  property string chartSeriesRange: ""
  property string chartRequestedRange: ""
  property bool chartLoading: false
  property double chartFetchedAt: 0

  // ---- FX rates ("USDEUR=X" -> 0.92) for the display currency.
  property var rates: ({})
  property var ratesRequested: []
  property int ratesRetries: 0

  readonly property string userAgent: "Mozilla/5.0 (X11; Linux x86_64) omarchy-stocks/0.3.0"
  readonly property bool loading: quotes.length === 0 && fetchError === ""
  readonly property int validCount: Model.validCount(quotes)
  // Quotes as displayed: converted into the display currency when a rate is known.
  readonly property var shownQuotes: Model.convertAll(quotes, displayCurrency, rates)
  readonly property var tapeItems: Model.tapeItems(shownQuotes, compact)
  readonly property var selectedQuote: selectedIndex >= 0 && selectedIndex < shownQuotes.length ? shownQuotes[selectedIndex] : null
  readonly property bool hasSelection: Model.isValid(selectedQuote)

  // Fallback pill text while the tape has nothing to show: "AAPL …" while
  // loading, "AAPL !" when every symbol failed.
  readonly property string label: shownQuotes.length > 0
    ? Model.barLabel(shownQuotes[0], compact)
    : Model.loadingLabel(symbols.length ? symbols[0] : "")
  readonly property string verticalText: {
    var first = Model.firstValidIndex(shownQuotes)
    if (first >= 0) return Model.verticalLabel(shownQuotes[first])
    if (shownQuotes.length > 0) return Model.verticalLabel(shownQuotes[0])
    return (symbols.length ? symbols[0] : "") + "\n…"
  }

  // ---- Presentation helpers shared by every row.
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(barForeground, 1.5)
  readonly property color urgentForeground: bar ? bar.urgent : Color.urgent

  // Up/down tints: settings override > theme palette (colors.toml) > fallback.
  property string themeGreen: ""
  property string themeRed: ""
  readonly property color upColor: upColorSetting !== "" ? upColorSetting : (themeGreen !== "" ? themeGreen : "#5fbf6f")
  readonly property color downColor: downColorSetting !== "" ? downColorSetting : (themeRed !== "" ? themeRed : urgentForeground)
  readonly property color signalBuyColor: "#61afef"

  function trendColor(quote) {
    if (Model.isDown(quote)) return downColor
    if (Model.isUp(quote)) return upColor
    return barForeground
  }

  function directionColor(series) {
    var d = Model.seriesDirection(series)
    if (d < 0) return downColor
    if (d > 0) return upColor
    return barForeground
  }

  function signalColor(action) {
    if (action === "Buy") return signalBuyColor
    if (action === "Sell") return downColor
    return mutedForeground
  }

  function sortScreen(key) {
    if (screenSortKey === key) screenSortDirection = -screenSortDirection
    else {
      screenSortKey = key
      screenSortDirection = key === "symbol" ? 1 : -1
    }
    screenList.contentY = 0
  }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.themeGreen = Model.parseThemeColor(text(), "green")
      root.themeRed = Model.parseThemeColor(text(), "red")
    }
    onLoadFailed: {
      root.themeGreen = ""
      root.themeRed = ""
    }
  }

  function open() {
    root.controller.show()
    refresh()
    ensureChartSeries(false)
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // A user-driven refresh gets a fresh retry budget.
  function refresh() {
    retries = 0
    startFetch()
  }

  function startFetch() {
    if (fetchProc.running) return
    fetchProc.command = Model.curlCommand(symbols, userAgent, "1d")
    fetchProc.running = true
  }

  function handleFetchOutput(text) {
    var raw = String(text || "")
    if (raw.replace(/\s+/g, "") === "") {
      // curl produced nothing (offline, DNS down): keep showing what we had.
      fetchError = "No response from Yahoo Finance"
      scheduleRetry()
      return
    }

    var parsed = Model.parseQuoteLines(raw, symbols)
    if (Model.validCount(parsed) === 0) {
      fetchError = parsed.length ? parsed[0].error : "No data"
      // Nothing better to show yet: surface the per-symbol errors as rows.
      if (quotes.length === 0) quotes = parsed
      if (Model.shouldRetry(parsed)) scheduleRetry()
      return
    }

    quotes = parsed
    lastUpdated = new Date()
    fetchError = ""
    retries = 0
    ensureRates()
    // Fresh quotes deserve fresh charts, unless the cache is under a minute old.
    if (root.opened && Date.now() - chartFetchedAt > 60000) ensureChartSeries(true)
  }

  function notifyScreenProblem(message) {
    var detail = String(message || "Screen data could not be updated")
    if (detail === lastScreenNotification) return
    lastScreenNotification = detail
    screenNotifyProc.command = ["notify-send", "Stocks screen update failed", detail]
    screenNotifyProc.running = true
  }

  function startScreenScan(force) {
    if (screenProc.running) return
    screenLoading = true
    screenFetchError = ""
    screenFetchWarning = ""
    screenProc.command = force ? ["node", screenScriptPath, "--force"] : ["node", screenScriptPath]
    screenProc.running = true
  }

  function handleScreenOutput(text) {
    var raw = String(text || "")
    if (raw.replace(/\s+/g, "") === "") {
      screenLoading = false
      screenFetchError = "The daily scanner returned no data"
      notifyScreenProblem(screenFetchError)
      return
    }
    var result
    try { result = JSON.parse(raw) }
    catch (error) {
      screenLoading = false
      screenFetchError = "Invalid response from the daily scanner"
      notifyScreenProblem(screenFetchError)
      return
    }
    screenLoading = false
    screenLoaded = true
    screenStocks = Array.isArray(result.stocks) ? result.stocks : []
    screenAsOf = String(result.asOf || "")
    screenCoverage = result.coverage || {}
    screenLastUpdated = result.generatedAt ? new Date(result.generatedAt) : new Date()
    screenFetchError = String(result.error || "")
    screenFetchWarning = String(result.warning || "")
    if (screenFetchError !== "") notifyScreenProblem(screenFetchError)
    else if (screenFetchWarning !== "") notifyScreenProblem(screenFetchWarning)
    else lastScreenNotification = ""
  }

  // ---- FX rates for the display currency: one pair per distinct quote
  //      currency, refreshed with every quote refresh (a couple of URLs).
  function ensureRates() {
    var pairs = Model.ratePairs(quotes, displayCurrency)
    if (!pairs.length || ratesProc.running) return
    ratesRequested = pairs
    ratesProc.command = Model.curlCommand(pairs, userAgent, "1d")
    ratesProc.running = true
  }

  function handleRatesOutput(text) {
    var raw = String(text || "")
    var fresh = raw.replace(/\s+/g, "") === "" ? {} : Model.parseRateLines(raw, ratesRequested)
    var missing = false
    for (var i = 0; i < ratesRequested.length; i++) if (fresh[ratesRequested[i]] === undefined) missing = true
    if (missing && ratesRetries < 3) {
      ratesRetries++
      ratesRetryTimer.restart()
    } else {
      ratesRetries = 0
    }
    var merged = {}
    for (var k in rates) merged[k] = rates[k]
    for (var f in fresh) merged[f] = fresh[f]
    rates = merged
  }

  function selectCurrency(step) {
    var next = Model.currencyCycle(displayCurrency, currencies, step)
    if (next === displayCurrency) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.currency = next
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function currencyLabel(quote) {
    if (!quote) return ""
    if (quote.converted) return quote.nativeCurrency + " → " + quote.currency
    return quote.currency
  }

  function scheduleRetry() {
    if (retries >= 3) return
    retries++
    retryTimer.restart()
  }

  // ---- Chart series for the non-1d ranges.
  function ensureChartSeries(force) {
    if (activeRange === "1d") return
    if (!force && chartSeriesRange === activeRange) return
    startChartFetch()
  }

  function startChartFetch() {
    if (chartProc.running) return
    chartRequestedRange = activeRange
    chartLoading = true
    chartProc.command = Model.curlCommand(symbols, userAgent, activeRange)
    chartProc.running = true
  }

  function handleChartOutput(text) {
    chartLoading = false
    var raw = String(text || "")
    if (raw.replace(/\s+/g, "") === "") return
    chartSeries = Model.parseSeriesLines(raw, symbols)
    chartSeriesRange = chartRequestedRange
    chartFetchedAt = Date.now()
    // The range moved on while we were fetching: go again for the new one.
    if (chartRequestedRange !== activeRange) Qt.callLater(root.startChartFetch)
  }

  // 1d series ride along with the (already converted) quote; other ranges
  // come from the raw chart cache and are converted here.
  function seriesFor(quote) {
    if (!quote) return []
    if (activeRange === "1d") return quote.series || []
    var raw = chartSeries[quote.symbol] || []
    return Model.convertSeries(raw, Model.rateFor(quote.nativeCurrency || quote.currency, displayCurrency, rates))
  }

  // Range chips persist their choice into this widget's shell.json entry, the
  // way omarchy.clock persists a right-click format change.
  function selectRange(range) {
    var next = Model.chartRange(range)
    if (next === activeRange) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.chartRange = next
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function selectQuote(index) {
    if (index >= 0 && index < quotes.length && Model.isValid(quotes[index])) selectedIndex = index
  }

  function openTradingView(symbol) {
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("xdg-open " + Model.shellQuote(Model.tradingViewUrl(symbol)))
  }

  function rangeLabel(range) {
    return { "1d": "1D", "5d": "5D", "1mo": "1M", "6mo": "6M", "1y": "1Y" }[range] || range
  }

  function formatStamp(ts, range) {
    if (ts === null || ts === undefined) return ""
    var d = new Date(ts * 1000)
    return Qt.formatDateTime(d, range === "1d" ? "HH:mm" : (range === "5d" ? "ddd HH:mm" : "d MMM"))
  }

  // Settings edits that change the symbol list invalidate everything shown.
  // Keyed on the joined string so re-injected-but-identical settings (any
  // shell.json save) do not trigger a refetch.
  onSymbolsKeyChanged: {
    selectedIndex = 0
    quotes = []
    chartSeries = {}
    chartSeriesRange = ""
    fetchError = ""
    lastUpdated = null
    retries = 0
    fetchProc.running = false
    chartProc.running = false
    Qt.callLater(root.startFetch)
    if (root.opened) Qt.callLater(function() { root.ensureChartSeries(true) })
  }

  onActiveRangeChanged: if (root.opened) ensureChartSeries(false)
  onDisplayCurrencyChanged: ensureRates()

  // Keep the detail block on a valid symbol when the list shrinks or a symbol fails.
  onQuotesChanged: {
    if (!Model.isValid(selectedQuote)) {
      var first = Model.firstValidIndex(quotes)
      selectedIndex = first >= 0 ? first : 0
    }
  }

  // Deferred so the first fetch sees the settings BarWidget injects right
  // after this component loads (Loader.onLoaded runs before callLater fires).
  Component.onCompleted: Qt.callLater(function() {
    root.startFetch()
    root.startScreenScan(false)
  })

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFetchOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // curl's own message ("Could not resolve host…") beats a generic one,
        // but only while we are in an error state.
        var message = String(text || "").split("\n")[0].replace(/^curl:\s*\(\d+\)\s*/, "").trim()
        if (message !== "" && root.fetchError !== "" && root.validCount === 0) root.fetchError = message
      }
    }
  }

  Process {
    id: screenProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleScreenOutput(text)
    }
  }

  Process { id: screenNotifyProc }

  Process {
    id: chartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleChartOutput(text)
    }
  }

  Process {
    id: ratesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRatesOutput(text)
    }
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.startFetch()
  }

  Timer {
    id: ratesRetryTimer
    interval: 2500
    onTriggered: root.ensureRates()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: screenRefreshTimer
    interval: 24 * 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.startScreenScan(false)
  }

  // Sparkline / chart line. Pure geometry comes from Model so the paint
  // handler only strokes the path.
  component SeriesCanvas: Canvas {
    id: canvas
    property var series: []
    property color lineColor: "white"
    property real lineWidth: 1.5
    property real pad: 2
    property bool fill: false
    property var referenceValue: null

    onSeriesChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onReferenceValueChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = Model.seriesPoints(canvas.series, canvas.width, canvas.height, canvas.pad)
      if (pts.length < 2) return

      if (canvas.fill) {
        var gradient = ctx.createLinearGradient(0, 0, 0, canvas.height)
        gradient.addColorStop(0, Qt.rgba(canvas.lineColor.r, canvas.lineColor.g, canvas.lineColor.b, 0.28))
        gradient.addColorStop(1, Qt.rgba(canvas.lineColor.r, canvas.lineColor.g, canvas.lineColor.b, 0.0))
        ctx.fillStyle = gradient
        ctx.beginPath()
        ctx.moveTo(pts[0].x, canvas.height)
        for (var f = 0; f < pts.length; f++) ctx.lineTo(pts[f].x, pts[f].y)
        ctx.lineTo(pts[pts.length - 1].x, canvas.height)
        ctx.closePath()
        ctx.fill()
      }

      var refY = Model.valueToY(canvas.referenceValue, Model.seriesBounds(canvas.series), canvas.height, canvas.pad)
      if (refY !== null) {
        ctx.strokeStyle = Qt.rgba(canvas.lineColor.r, canvas.lineColor.g, canvas.lineColor.b, 0.35)
        ctx.lineWidth = 1
        ctx.setLineDash([3, 3])
        ctx.beginPath()
        ctx.moveTo(pts[0].x, refY)
        ctx.lineTo(pts[pts.length - 1].x, refY)
        ctx.stroke()
        ctx.setLineDash([])
      }

      ctx.strokeStyle = canvas.lineColor
      ctx.lineWidth = canvas.lineWidth
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(pts[0].x, pts[0].y)
      for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
      ctx.stroke()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // The screen table uses equal edge insets. The final analyst column flexes
    // to consume the remaining usable card width.
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onReturnRequested: root.refresh()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(8)

        // ---- Header: tab switcher and freshness.
        Item {
          width: parent.width
          height: Math.max(headerTitle.implicitHeight, tabs.implicitHeight)

          Text {
            id: headerTitle
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "Stocks"
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Row {
            id: tabs
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: ["Watchlist", "Screen"]

              Rectangle {
                id: tabChip
                required property string modelData
                required property int index
                readonly property bool selected: index === root.activeTab
                width: tabText.implicitWidth + Style.space(16)
                height: tabText.implicitHeight + Style.space(7)
                radius: Style.cornerRadius
                color: tabChip.selected
                  ? Style.selectedFillFor(root.barForeground, Color.accent)
                  : (tabMouse.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

                Text {
                  id: tabText
                  anchors.centerIn: parent
                  text: tabChip.modelData
                  color: tabChip.selected ? root.barForeground : root.mutedForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: tabChip.selected
                }

                MouseArea {
                  id: tabMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTab = tabChip.index
                }
              }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var stamp = root.activeTab === 0 ? root.lastUpdated : root.screenLastUpdated
              var busy = root.activeTab === 0 ? root.loading : root.screenLoading
              return stamp ? "Updated " + Qt.formatTime(stamp, "HH:mm") : (busy ? "Loading…" : "")
            }
            color: root.mutedForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Chart range and display currency only apply to the watchlist tab.
        Row {
          id: chips
          visible: root.activeTab === 0
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          Repeater {
            model: Model.CHART_RANGES

            Rectangle {
              id: chip
              required property string modelData
              readonly property bool selected: modelData === root.activeRange
              width: chipText.implicitWidth + Style.space(12)
              height: chipText.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: chip.selected
                ? Style.selectedFillFor(root.barForeground, Color.accent)
                : (chipMouse.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

              Text {
                id: chipText
                anchors.centerIn: parent
                text: root.rangeLabel(chip.modelData)
                color: chip.selected ? root.barForeground : root.mutedForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: chip.selected
              }

              MouseArea {
                id: chipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectRange(chip.modelData)
              }
            }
          }

          Item { width: Style.space(8); height: 1 }

          // Display currency: click cycles forward, right-click back.
          Rectangle {
            id: currencyChip
            readonly property bool active: root.displayCurrency !== ""
            width: currencyText.implicitWidth + Style.space(12)
            height: currencyText.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: currencyChip.active
              ? Style.selectedFillFor(root.barForeground, Color.accent)
              : (currencyMouse.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

            Text {
              id: currencyText
              anchors.centerIn: parent
              text: (root.displayCurrency !== "" ? root.displayCurrency : "Native") + " ⇄"
              color: currencyChip.active ? root.barForeground : root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: currencyChip.active
            }

            MouseArea {
              id: currencyMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onClicked: function(mouse) { root.selectCurrency(mouse.button === Qt.RightButton ? -1 : 1) }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---- One row per symbol: SYM · name · sparkline · price · change.
        Column {
          visible: root.activeTab === 0
          width: parent.width
          spacing: 0

          Repeater {
            model: root.shownQuotes

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool valid: Model.isValid(modelData)
              readonly property bool selected: index === root.selectedIndex && root.hasSelection
              readonly property var series: root.activeRange === "1d"
                ? (modelData.series || [])
                : Model.convertSeries(root.chartSeries[modelData.symbol] || [],
                    Model.rateFor(modelData.nativeCurrency || modelData.currency, root.displayCurrency, root.rates))

              width: parent.width
              height: symbolText.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: row.selected
                ? Style.selectedFillFor(root.barForeground, Color.accent)
                : (rowMouse.containsMouse && row.valid ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

              Text {
                id: symbolText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(64)
                text: row.modelData.symbol
                elide: Text.ElideRight
                color: row.valid ? root.barForeground : root.mutedForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                anchors.left: symbolText.right
                anchors.right: spark.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.valid ? row.modelData.name : (row.modelData.error || "No data")
                elide: Text.ElideRight
                color: root.mutedForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: !row.valid
              }

              SeriesCanvas {
                id: spark
                anchors.right: priceText.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(72)
                height: Style.space(20)
                visible: row.valid
                series: row.series
                lineColor: root.directionColor(row.series)
                lineWidth: 1.25
                pad: 1.5
              }

              Text {
                id: priceText
                anchors.right: changeText.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(76)
                horizontalAlignment: Text.AlignRight
                text: row.valid ? Model.formatPrice(row.modelData.price) : ""
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                id: changeText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(112)
                horizontalAlignment: Text.AlignRight
                text: row.valid ? Model.formatChange(row.modelData) : ""
                color: root.trendColor(row.modelData)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: row.valid ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (row.valid) root.selectQuote(row.index)
              }
            }
          }
        }

        Text {
          visible: root.activeTab === 0 && root.loading
          leftPadding: Style.space(8)
          text: "Fetching quotes…"
          color: root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        PanelSeparator {
          visible: root.activeTab === 0 && root.hasSelection
          foreground: root.barForeground
        }

        // ---- Detail block for the selected symbol.
        Column {
          id: detail
          visible: root.activeTab === 0 && root.hasSelection
          width: parent.width
          spacing: Style.space(8)

          readonly property var quote: root.selectedQuote
          readonly property var series: root.hasSelection ? root.seriesFor(root.selectedQuote) : []
          readonly property var bounds: Model.seriesBounds(series)
          readonly property real statLabelWidth: Style.space(84)
          readonly property real statValueWidth: (width - Style.space(16)) / 2 - statLabelWidth

          Item {
            width: parent.width
            height: Math.max(nameColumn.implicitHeight, priceColumn.implicitHeight)

            Column {
              id: nameColumn
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: priceColumn.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: detail.quote ? (detail.quote.name || detail.quote.symbol) : ""
                elide: Text.ElideRight
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                width: parent.width
                text: detail.quote
                  ? [detail.quote.symbol, detail.quote.exchange, root.currencyLabel(detail.quote)].filter(function(p) { return !!p }).join(" · ")
                  : ""
                elide: Text.ElideRight
                color: root.mutedForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              id: priceColumn
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                anchors.right: parent.right
                text: detail.quote ? Model.formatPrice(detail.quote.price) : ""
                color: root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }
              Text {
                anchors.right: parent.right
                text: detail.quote ? Model.formatChange(detail.quote) : ""
                color: root.trendColor(detail.quote)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(112)

            SeriesCanvas {
              id: bigChart
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              series: detail.series
              lineColor: root.directionColor(detail.series)
              lineWidth: 1.75
              pad: 4
              fill: true
              referenceValue: root.activeRange === "1d" && detail.quote ? detail.quote.prevClose : null
            }

            Text {
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              text: detail.bounds ? Model.formatPrice(detail.bounds.max) : ""
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.bottom: parent.bottom
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              text: detail.bounds ? Model.formatPrice(detail.bounds.min) : ""
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.centerIn: parent
              visible: detail.series.length < 2
              text: root.chartLoading ? "Loading chart…" : "No chart data"
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }
          }

          Item {
            width: parent.width
            height: firstStamp.implicitHeight
            visible: detail.series.length >= 2

            Text {
              id: firstStamp
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              text: detail.series.length ? root.formatStamp(detail.series[0].t, root.activeRange) : ""
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              text: detail.series.length ? root.formatStamp(detail.series[detail.series.length - 1].t, root.activeRange) : ""
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Grid {
            id: stats
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            columns: 4
            columnSpacing: 0
            rowSpacing: Style.space(4)

            readonly property var entries: detail.quote ? [
              ["Prev close", Model.formatPrice(detail.quote.prevClose)],
              ["Open", Model.formatPrice(detail.quote.open)],
              ["Day range", detail.quote.dayLow !== null && detail.quote.dayHigh !== null
                ? Model.formatPrice(detail.quote.dayLow) + " – " + Model.formatPrice(detail.quote.dayHigh) : ""],
              ["52w range", detail.quote.week52Low !== null && detail.quote.week52High !== null
                ? Model.formatPrice(detail.quote.week52Low) + " – " + Model.formatPrice(detail.quote.week52High) : ""],
              ["Volume", Model.formatVolume(detail.quote.volume)],
              ["Last trade", detail.quote.marketTime !== null ? Qt.formatDateTime(new Date(detail.quote.marketTime * 1000), "ddd HH:mm") : ""]
            ] : []

            Repeater {
              model: stats.entries.length * 2

              Text {
                required property int index
                readonly property bool isLabel: index % 2 === 0
                readonly property var entry: stats.entries[Math.floor(index / 2)]
                width: isLabel ? detail.statLabelWidth : detail.statValueWidth
                text: entry ? (isLabel ? entry[0] : (entry[1] || "—")) : ""
                elide: Text.ElideRight
                color: isLabel ? root.mutedForeground : root.barForeground
                font.family: root.fontFamily
                font.pixelSize: isLabel ? Style.font.caption : Style.font.bodySmall
              }
            }
          }

          Text {
            id: yahooLink
            leftPadding: Style.space(8)
            text: "Open on TradingView ↗"
            color: linkMouse.containsMouse ? root.barForeground : root.mutedForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: linkMouse.containsMouse

            MouseArea {
              id: linkMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (detail.quote) root.openTradingView(detail.quote.symbol)
            }
          }
        }

        // ---- Screen tab: every current S&P 500 constituent that passed all
        //      four criteria during the latest daily scan.
        Column {
          id: screen
          visible: root.activeTab === 1
          width: parent.width
          spacing: Style.space(5)

          Text {
            width: parent.width
            leftPadding: Style.space(8)
            rightPadding: Style.space(8)
            text: "S&P 500 · EMA200 ↑ 20D/5Y · Target >20% · Weekly MACD/RSI"
            elide: Text.ElideRight
            color: root.mutedForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            width: parent.width
            height: Math.max(screenStamp.implicitHeight, refreshScreenButton.height)

            Text {
              id: screenStamp
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: refreshScreenButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.screenAsOf !== ""
                ? root.screenRows.length + " matches · " + root.screenAsOf + " · USD"
                : (root.screenLoading ? "Scanning the current S&P 500…" : "No completed scan")
              elide: Text.ElideRight
              color: root.mutedForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }

            Rectangle {
              id: refreshScreenButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: refreshScreenText.implicitWidth + Style.space(12)
              height: refreshScreenText.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: refreshScreenMouse.containsMouse
                ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"

              Text {
                id: refreshScreenText
                anchors.centerIn: parent
                text: root.screenLoading ? "Refreshing…" : "Refresh"
                color: root.screenLoading ? root.mutedForeground : root.barForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: refreshScreenMouse
                anchors.fill: parent
                enabled: !root.screenLoading
                hoverEnabled: enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.startScreenScan(true)
              }
            }
          }

          Row {
            id: screenHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: 0

            Repeater {
              model: [
                { text: "Symbol", key: "symbol", width: 50, align: Text.AlignLeft },
                { text: "Price", key: "price", width: 70, align: Text.AlignRight },
                { text: "EMA200", key: "ema200", width: 126, align: Text.AlignRight },
                { text: "MACD", key: "macd", width: 56, align: Text.AlignRight },
                { text: "RSI", key: "rsi", width: 56, align: Text.AlignRight },
                { text: "Analysts · Δ", key: "targetUpsidePct", width: 190, align: Text.AlignRight }
              ]

              Item {
                required property var modelData
                required property int index
                width: index === 5 ? screenHeader.width - Style.space(358) : Style.space(modelData.width)
                height: headerText.implicitHeight

                Text {
                  id: headerText
                  anchors.fill: parent
                  text: parent.modelData.text + (root.screenSortKey === parent.modelData.key
                    ? (root.screenSortDirection > 0 ? " ▲" : " ▼") : "")
                  horizontalAlignment: parent.modelData.align
                  color: headerMouse.containsMouse ? root.barForeground : root.mutedForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: headerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sortScreen(parent.modelData.key)
                }
              }
            }
          }

          Flickable {
            id: screenList
            width: parent.width
            // Keep the panel compact while exposing every qualifying stock
            // through the mouse wheel or touchpad.
            height: Math.min(screenRowsColumn.implicitHeight, Style.space(217))
            contentWidth: width
            contentHeight: screenRowsColumn.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: screenRowsColumn
              width: screenList.width
              spacing: 0

              Repeater {
                model: root.sortedScreenRows

                Rectangle {
                id: screenRow
                required property var modelData
                width: parent.width
                height: Style.space(31)
                radius: Style.cornerRadius
                color: !modelData.qualifies
                  ? Qt.rgba(root.downColor.r, root.downColor.g, root.downColor.b, 0.10)
                  : (screenMouse.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

                Row {
                  id: screenValues
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    width: Style.space(50)
                    text: screenRow.modelData.symbol
                    color: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    width: Style.space(70)
                    text: Model.formatPrice(screenRow.modelData.price)
                    horizontalAlignment: Text.AlignRight
                    color: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: Style.space(126)
                    text: Model.formatPrice(screenRow.modelData.ema200)
                      + " (" + Model.formatSignedPercent(screenRow.modelData.aboveEmaPct) + ")"
                    horizontalAlignment: Text.AlignRight
                    color: screenRow.modelData.aboveEma ? root.upColor : root.downColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: Style.space(56)
                    text: screenRow.modelData.macd.action
                    horizontalAlignment: Text.AlignRight
                    color: root.signalColor(screenRow.modelData.macd.action)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: screenRow.modelData.macd.action !== "Neutral"
                  }
                  Text {
                    width: Style.space(56)
                    text: screenRow.modelData.rsi.action
                    horizontalAlignment: Text.AlignRight
                    color: root.signalColor(screenRow.modelData.rsi.action)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: screenRow.modelData.rsi.action !== "Neutral"
                  }
                  Text {
                    width: screenValues.width - Style.space(358)
                    text: screenRow.modelData.analystCount + " · "
                      + Model.formatSignedPercent(screenRow.modelData.targetUpsidePct)
                    horizontalAlignment: Text.AlignRight
                    color: screenRow.modelData.targetUpside ? root.upColor : root.downColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: screenMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openTradingView(screenRow.modelData.symbol)
                }
                }
              }
            }
          }

          Text {
            visible: root.screenLoading
            leftPadding: Style.space(8)
            text: root.screenLoaded ? "Refreshing the full S&P 500 screen…" : "Running the full S&P 500 screen…"
            color: root.mutedForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---- Footer: the failure reason when there is one, hints otherwise.
        Text {
          width: parent.width
          leftPadding: Style.space(8)
          rightPadding: Style.space(8)
          text: root.activeTab === 0
            ? (root.fetchError !== ""
                ? "Could not update: " + root.fetchError
                : "Click a row for details · Middle-click the tape to refresh · Right-click to pause")
            : (root.screenFetchError !== ""
                ? "Could not update: " + root.screenFetchError + (root.screenRows.length ? " · showing the last successful scan" : "")
                : (root.screenFetchWarning !== ""
                    ? "Partial update: " + root.screenFetchWarning
                    : "All passing stocks are shown · Analysts is coverage count · Δ is target change from current price"))
          wrapMode: Text.WordWrap
          color: (root.activeTab === 0 ? root.fetchError : (root.screenFetchError || root.screenFetchWarning)) !== ""
            ? root.urgentForeground : root.mutedForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
