const test = require("node:test")
const assert = require("node:assert/strict")
const Screen = require("../Screen.js")

test("parseCsv handles quoted commas and escaped quotes", () => {
  const rows = Screen.parseCsv('Symbol,Security,Location\nAAA,"A, Inc.","New ""York"""\n')
  assert.deepEqual(rows, [{ Symbol: "AAA", Security: "A, Inc.", Location: 'New "York"' }])
})

test("Yahoo symbols replace index dots with dashes", () => {
  assert.equal(Screen.yahooSymbol("brk.b"), "BRK-B")
  assert.equal(Screen.yahooSymbol("NVDA"), "NVDA")
})

test("EMA and cache freshness are deterministic", () => {
  assert.deepEqual(Screen.ema([10, 20, 30], 3), [10, 15, 22.5])
  assert.equal(Screen.localDateKey(new Date(2026, 8, 7, 12)), "2026-09-07")
  assert.equal(Screen.cacheIsFresh({ schemaVersion: 2, dateKey: "2026-09-07", stocks: [] }, new Date(2026, 8, 7, 23)), true)
  assert.equal(Screen.cacheIsFresh({ schemaVersion: 2, dateKey: "2026-09-06", stocks: [] }, new Date(2026, 8, 7, 1)), false)
})

test("parseYahooHistory evaluates EMA criteria and emits weekly signals", () => {
  const length = 1500
  const closes = Array.from({ length }, (_, index) => 50 * Math.pow(1.002, index))
  const timestamps = Array.from({ length }, (_, index) => 1600000000 + index * 86400)
  const data = { chart: { result: [{
    meta: { regularMarketPrice: closes.at(-1) }, timestamp: timestamps,
    indicators: { quote: [{ close: closes }], adjclose: [{ adjclose: closes }] }
  }] } }
  const row = Screen.parseYahooHistory(data, { Symbol: "AAA", Security: "A Corp" })
  assert.equal(row.symbol, "AAA")
  assert.equal(row.name, "A Corp")
  assert.equal(row.technicalPass, true)
  assert.ok(row.ema200 > row.ema20d)
  assert.ok(row.ema20d > row.ema5y)
  assert.equal(row.macd.action, "Buy")
  assert.equal(row.rsi.action, "Sell")
})

test("mapLimit returns all results and captures individual failures", async () => {
  const result = await Screen.mapLimit([1, 2, 3], 2, async value => {
    if (value === 2) throw new Error("broken")
    return value * 2
  })
  assert.deepEqual(result, [2, { error: "broken" }, 6])
})
