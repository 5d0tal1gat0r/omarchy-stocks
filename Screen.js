#!/usr/bin/env node

// Daily, cached S&P 500 screen. This runs outside QML so network work across
// the full index is bounded and does not block the shell's UI thread.

"use strict"

const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const CONSTITUENTS_URL = "https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv"
const YAHOO_CHART_URL = "https://query1.finance.yahoo.com/v8/finance/chart/"
const USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) omarchy-stocks/0.3.0"
const DAY_MS = 24 * 60 * 60 * 1000
const SESSION_5Y = 252 * 5

function cachePath() {
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache")
  return path.join(base, "omarchy-stocks", "screen.json")
}

function localDateKey(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    year: "numeric", month: "2-digit", day: "2-digit"
  }).formatToParts(date)
  const value = Object.fromEntries(parts.map(part => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

function readCache(file = cachePath()) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")) } catch (_) { return null }
}

function cacheIsFresh(cache, now = new Date()) {
  const coverage = cache && cache.coverage
  return Boolean(cache && cache.dateKey === localDateKey(now) && Array.isArray(cache.stocks)
    && !cache.error && !cache.warning
    && (!coverage || (!coverage.historyErrors && !coverage.analystErrors)))
}

function writeCache(data, file = cachePath()) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const temporary = `${file}.${process.pid}.tmp`
  fs.writeFileSync(temporary, JSON.stringify(data), "utf8")
  fs.renameSync(temporary, file)
}

// RFC-4180 fields, including commas and escaped quotes inside quoted names.
function parseCsv(text) {
  const rows = []
  let row = []
  let field = ""
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (quoted) {
      if (char === '"' && text[i + 1] === '"') { field += '"'; i++ }
      else if (char === '"') quoted = false
      else field += char
    } else if (char === '"') quoted = true
    else if (char === ",") { row.push(field); field = "" }
    else if (char === "\n") { row.push(field.replace(/\r$/, "")); rows.push(row); row = []; field = "" }
    else field += char
  }
  if (field || row.length) { row.push(field.replace(/\r$/, "")); rows.push(row) }
  if (rows.length < 2) return []
  const headers = rows[0]
  return rows.slice(1).filter(values => values.some(Boolean)).map(values => {
    const item = {}
    headers.forEach((header, index) => { item[header] = values[index] || "" })
    return item
  })
}

function yahooSymbol(symbol) {
  return String(symbol || "").trim().toUpperCase().replace(/\./g, "-")
}

async function fetchJson(url, attempts = 3, extraHeaders = {}) {
  let lastError
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const response = await fetch(url, {
        headers: { "user-agent": USER_AGENT, accept: "application/json,text/plain,*/*", ...extraHeaders },
        signal: AbortSignal.timeout(15000)
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      return await response.json()
    } catch (error) {
      lastError = error
      if (attempt + 1 < attempts) await new Promise(resolve => setTimeout(resolve, 400 * (attempt + 1)))
    }
  }
  throw lastError
}

async function fetchText(url) {
  const response = await fetch(url, { headers: { "user-agent": USER_AGENT }, signal: AbortSignal.timeout(15000) })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.text()
}

async function mapLimit(items, limit, mapper) {
  const results = new Array(items.length)
  let next = 0
  async function worker() {
    while (true) {
      const index = next++
      if (index >= items.length) return
      try { results[index] = await mapper(items[index], index) }
      catch (error) { results[index] = { error: String(error && error.message || error) } }
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return results
}

function ema(values, period) {
  const multiplier = 2 / (period + 1)
  const out = []
  let previous = null
  for (const raw of values || []) {
    const value = Number(raw)
    if (!Number.isFinite(value)) continue
    previous = previous === null ? value : previous + (value - previous) * multiplier
    out.push(previous)
  }
  return out
}

function weeklySeries(timestamps, closes) {
  const byWeek = new Map()
  const cutoff = timestamps.length ? timestamps[timestamps.length - 1] - 5 * 365.25 * 86400 : 0
  for (let i = 0; i < timestamps.length && i < closes.length; i++) {
    if (!Number.isFinite(timestamps[i]) || !Number.isFinite(closes[i]) || timestamps[i] < cutoff) continue
    const date = new Date(timestamps[i] * 1000)
    // Monday-based week key; the last trading close replaces earlier closes.
    const day = (date.getUTCDay() + 6) % 7
    const monday = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() - day))
    byWeek.set(monday.toISOString().slice(0, 10), { t: timestamps[i], c: closes[i] })
  }
  return Array.from(byWeek.values())
}

function macdIndicator(series) {
  const closes = (series || []).map(point => point.c)
  if (closes.length < 35) return { value: null, signal: null, action: "Neutral" }
  const fast = ema(closes, 12)
  const slow = ema(closes, 26)
  const line = closes.map((_, index) => fast[index] - slow[index])
  const signals = ema(line, 9)
  const value = line.at(-1)
  const signal = signals.at(-1)
  return { value, signal, action: value > signal ? "Buy" : value < signal ? "Sell" : "Neutral" }
}

function rsiIndicator(series) {
  const closes = (series || []).map(point => point.c)
  const period = 14
  if (closes.length < period + 1) return { value: null, action: "Neutral" }
  let gains = 0
  let losses = 0
  for (let i = 1; i <= period; i++) {
    const change = closes[i] - closes[i - 1]
    if (change > 0) gains += change
    else losses -= change
  }
  let averageGain = gains / period
  let averageLoss = losses / period
  for (let i = period + 1; i < closes.length; i++) {
    const change = closes[i] - closes[i - 1]
    averageGain = (averageGain * (period - 1) + (change > 0 ? change : 0)) / period
    averageLoss = (averageLoss * (period - 1) + (change < 0 ? -change : 0)) / period
  }
  const value = averageLoss === 0 ? (averageGain === 0 ? 50 : 100) : 100 - 100 / (1 + averageGain / averageLoss)
  return { value, action: value <= 30 ? "Buy" : value >= 70 ? "Sell" : "Neutral" }
}

function parseYahooHistory(data, constituent) {
  const result = data && data.chart && data.chart.result && data.chart.result[0]
  if (!result) throw new Error(data && data.chart && data.chart.error && data.chart.error.description || "No chart data")
  const timestamps = result.timestamp || []
  const quoteCloses = result.indicators && result.indicators.quote && result.indicators.quote[0] && result.indicators.quote[0].close || []
  const adjusted = result.indicators && result.indicators.adjclose && result.indicators.adjclose[0] && result.indicators.adjclose[0].adjclose || []
  const cleanTimestamps = []
  const closes = []
  for (let i = 0; i < timestamps.length; i++) {
    const close = Number(adjusted[i] ?? quoteCloses[i])
    if (!Number.isFinite(close)) continue
    cleanTimestamps.push(Number(timestamps[i]))
    closes.push(close)
  }
  if (closes.length < SESSION_5Y + 201) throw new Error("Insufficient 10-year history")
  const ema200Series = ema(closes, 200)
  const price = Number(result.meta && result.meta.regularMarketPrice)
  const latestPrice = Number.isFinite(price) ? price : closes.at(-1)
  const ema200 = ema200Series.at(-1)
  const ema20d = ema200Series.at(-21)
  const ema5y = ema200Series.at(-(SESSION_5Y + 1))
  const weekly = weeklySeries(cleanTimestamps, closes)
  return {
    symbol: yahooSymbol(constituent.Symbol), name: constituent.Security || constituent.Symbol,
    price: latestPrice, ema200, ema20d, ema5y,
    asOf: new Date(cleanTimestamps.at(-1) * 1000).toISOString().slice(0, 10),
    macd: macdIndicator(weekly), rsi: rsiIndicator(weekly),
    technicalPass: latestPrice > ema200 && ema200 > ema20d && ema200 > ema5y
  }
}

async function fetchHistory(constituent) {
  const symbol = yahooSymbol(constituent.Symbol)
  const url = `${YAHOO_CHART_URL}${encodeURIComponent(symbol)}?range=10y&interval=1d&events=div%2Csplits&includeAdjustedClose=true`
  return parseYahooHistory(await fetchJson(url), constituent)
}

async function createYahooSession() {
  const response = await fetch("https://fc.yahoo.com/", {
    headers: { "user-agent": USER_AGENT }, signal: AbortSignal.timeout(15000), redirect: "manual"
  })
  const cookie = String(response.headers.get("set-cookie") || "").split(";")[0]
  if (!cookie) throw new Error("Yahoo session cookie unavailable")
  const crumbResponse = await fetch("https://query1.finance.yahoo.com/v1/test/getcrumb", {
    headers: { "user-agent": USER_AGENT, cookie }, signal: AbortSignal.timeout(15000)
  })
  if (!crumbResponse.ok) throw new Error(`Yahoo session HTTP ${crumbResponse.status}`)
  const crumb = (await crumbResponse.text()).trim()
  if (!crumb) throw new Error("Yahoo session token unavailable")
  return { cookie, crumb }
}

async function fetchAnalysts(stock, session) {
  const url = "https://query1.finance.yahoo.com/v10/finance/quoteSummary/"
    + `${encodeURIComponent(stock.symbol)}?modules=financialData&crumb=${encodeURIComponent(session.crumb)}`
  const data = await fetchJson(url, 3, { cookie: session.cookie })
  const financial = data && data.quoteSummary && data.quoteSummary.result && data.quoteSummary.result[0]
    && data.quoteSummary.result[0].financialData
  if (!financial) return { unavailable: true }
  const target = Number(financial.targetMeanPrice && financial.targetMeanPrice.raw)
  const analystCount = Number(financial.numberOfAnalystOpinions && financial.numberOfAnalystOpinions.raw)
  if (!Number.isFinite(target)) return { unavailable: true }
  return { ...stock, target, analystCount: Number.isFinite(analystCount) ? analystCount : 0,
    targetUpsidePct: (target / stock.price - 1) * 100 }
}

async function runScreen() {
  const csv = await fetchText(CONSTITUENTS_URL)
  const constituents = parseCsv(csv).filter(row => row.Symbol)
  if (constituents.length < 450) throw new Error(`Constituent list is incomplete (${constituents.length})`)
  process.stderr.write(`Screening ${constituents.length} S&P 500 constituents\n`)
  const histories = await mapLimit(constituents, 12, fetchHistory)
  const validHistories = histories.filter(stock => stock && !stock.error)
  const historyUnavailable = histories.filter(stock => stock && stock.error === "Insufficient 10-year history").length
  const historyErrors = constituents.length - validHistories.length - historyUnavailable
  const technical = validHistories.filter(stock => stock.technicalPass)
  process.stderr.write(`${technical.length} passed the EMA tests; fetching analyst targets\n`)
  const yahooSession = await createYahooSession()
  const analystRows = await mapLimit(technical, 6, stock => fetchAnalysts(stock, yahooSession))
  const validAnalysts = analystRows.filter(stock => stock && Number.isFinite(stock.target))
  const analystUnavailable = analystRows.filter(stock => stock && stock.unavailable).length
  const analystErrors = analystRows.filter(stock => stock && stock.error).length
  if (historyErrors || analystErrors) {
    throw new Error([historyErrors ? `${historyErrors} price histories` : "",
      analystErrors ? `${analystErrors} analyst targets` : ""].filter(Boolean).join(" and ") + " could not be fetched")
  }
  const stocks = validAnalysts.filter(stock => stock.targetUpsidePct > 20)
    .sort((a, b) => b.targetUpsidePct - a.targetUpsidePct)
    .map(stock => {
      const { technicalPass, targetUpsidePct, ...row } = stock
      return row
    })
  const asOf = validHistories.map(stock => stock.asOf).sort().at(-1) || localDateKey()
  return {
    schemaVersion: 1,
    dateKey: localDateKey(),
    generatedAt: new Date().toISOString(),
    asOf,
    stocks,
    coverage: {
      constituents: constituents.length,
      priceHistories: validHistories.length,
      technicalPassers: technical.length,
      analystTargets: validAnalysts.length,
      matches: stocks.length,
      historyUnavailable,
      analystUnavailable,
      historyErrors,
      analystErrors
    }
  }
}

async function main() {
  const file = cachePath()
  const cached = readCache(file)
  if (!process.argv.includes("--force") && cacheIsFresh(cached)) {
    process.stdout.write(JSON.stringify(cached))
    return
  }
  try {
    const result = await runScreen()
    writeCache(result, file)
    process.stdout.write(JSON.stringify(result))
  } catch (error) {
    if (cached && Array.isArray(cached.stocks) && !cached.error && !cached.warning
        && (!cached.coverage || (!cached.coverage.historyErrors && !cached.coverage.analystErrors))) {
      process.stdout.write(JSON.stringify({ ...cached, stale: true, error: String(error && error.message || error) }))
      return
    }
    process.stdout.write(JSON.stringify({ stocks: [], error: String(error && error.message || error) }))
    process.exitCode = 1
  }
}

if (require.main === module) main()

module.exports = {
  parseCsv, yahooSymbol, ema, weeklySeries, macdIndicator, rsiIndicator,
  parseYahooHistory, localDateKey, cacheIsFresh, mapLimit
}
