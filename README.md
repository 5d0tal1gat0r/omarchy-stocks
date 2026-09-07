# Stocks for Omarchy

A Wall-Street-style ticker tape for the Omarchy Quattro bar. The tape scrolls
your symbols (`AMZN 226.13 ▲0.42%  •  NVDA …`) in the theme's green/red; click
it for a panel with sparklines, a detail chart with range selector, key stats
and a currency switch. A second tab dynamically shows every S&P 500 stock that
passes the momentum and analyst-upside screen. Quotes and FX rates come from
Yahoo Finance — no API key.

![preview](preview.png)

## Install

```sh
omarchy plugin add https://github.com/5d0tal1gat0r/omarchy-stocks.git --enable
```

The widget lands in the bar's center section. Move it with:

```sh
omarchy bar move io.github.5d0tal1gat0r.stocks --section right
```

## Usage

| where | action | effect |
|-------|--------|--------|
| tape | left click | open / close the panel (Esc closes, Tab switches panels) |
| tape | middle click | refresh now |
| tape | right click / hover | pause the tape (hover pauses while pointing) |
| panel | `1D 5D 1M 6M 1Y` | chart range (persisted) |
| panel | `USD ⇄` chip | left click: next currency · right click: previous · `Native` = each quote in its own currency |
| panel | click a row | show that symbol's chart and stats |
| panel | `Open on TradingView ↗` | open the selected symbol in your browser |
| panel | `Screen` | show every S&P 500 stock above a rising EMA200 with >20% consensus target upside |
| screen | click a symbol | open that symbol on TradingView |
| screen | `Refresh` | force a new full-index scan now |

IPC (for keybindings): `omarchy-shell io.github.5d0tal1gat0r.stocks toggle|open|close|refresh|pause`

## Configure

Settings live on the widget's entry in `~/.config/omarchy/shell.json` and apply
instantly:

```sh
omarchy bar set io.github.5d0tal1gat0r.stocks symbols '["AAPL","MSFT","BTC-USD","^GSPC"]' --json
omarchy bar set io.github.5d0tal1gat0r.stocks tickerWidth 260
omarchy bar set io.github.5d0tal1gat0r.stocks scrollSpeed 30
omarchy bar set io.github.5d0tal1gat0r.stocks currency EUR
omarchy bar set io.github.5d0tal1gat0r.stocks compact true --json    # "AAPL ▲0.42%" without the price
```

| key | default | meaning |
|-----|---------|---------|
| `symbols` | `["AMZN","NVDA","SPCX","GOOGL"]` | any Yahoo Finance symbols (stocks, ETFs, `BTC-USD`, `EURUSD=X`, `^GSPC`); a comma-separated string also works |
| `refreshMinutes` | `5` | quote refresh interval (minimum 1) |
| `tickerWidth` | `180` | tape width in px (minimum 80) |
| `scrollSpeed` | `20` | tape speed in px/s; `0` = static |
| `compact` | `false` | drop the price from the tape |
| `chartRange` | `1d` | one of `1d 5d 1mo 6mo 1y` (the panel chips set this) |
| `currency` | `""` (native) | show every price in this currency, e.g. `EUR` (the panel chip sets this) |
| `currencies` | `["USD","EUR","GBP","JPY","CHF"]` | what the currency chip cycles through |
| `upColor` / `downColor` | theme `green` / `red` | override the tints with a hex color, e.g. `"#a6e3a1"` |

Unknown symbols show as `Not Found` in the panel and are left out of the tape.
Colors follow the current theme's `colors.toml`; themes without a `green` get a
neutral fallback.

## Screen

The screen downloads the current S&P 500 constituent list and includes every
stock that passes all of these tests:

1. present in the S&P 500 constituent list;
2. adjusted close above the 200-session exponential moving average;
3. EMA200 above its levels 20 trading sessions and five years earlier; and
4. Yahoo mean analyst price target more than 20% above the close.

The scan runs automatically when the shell starts and every 24 hours. Its
result is cached in `~/.cache/omarchy-stocks/screen.json`; the Refresh button
forces an immediate rescan. Price histories are fetched first for the entire
index, and analyst targets are fetched only for stocks that pass the EMA tests.
If an update fails, the plugin sends a desktop notification and keeps showing
the last successful cache. Screening inputs come from the
[S&P 500 constituent dataset](https://github.com/datasets/s-and-p-500-companies/blob/main/data/constituents.csv),
[Yahoo Finance chart data](https://query1.finance.yahoo.com/v8/finance/chart/NVDA?range=10y&interval=1d),
and [Yahoo Finance analyst target data](https://finance.yahoo.com/quote/NVDA/analysis/).

For longer-term context, the scanner derives five years of weekly closes for
every displayed symbol. MACD uses the 12/26-week line and 9-week signal line
(`Buy` when MACD is above its signal, `Sell` when below); RSI uses the 14-week
Wilder calculation (`Buy` at or below 30, `Sell` at or above 70, otherwise
`Neutral`). These are technical indicators, not investment advice.

## Develop

Clone this repository (or your fork), then from its root:

```sh
node --test test/*.test.js                                  # logic unit tests
qmllint -I /usr/share/omarchy/shell Panel.qml
omarchy plugin validate "$PWD"
omarchy plugin add "$PWD" --enable                          # installs a clone into ~/.config/omarchy/plugins/
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/io.github.5d0tal1gat0r.stocks/
omarchy restart shell                                       # QML is cached per shell process; a restart loads the edit
qs log -p /usr/share/omarchy/shell --tail 100               # shell log
```

`Model.js` holds the panel's pure logic. `Screen.js` performs the cached daily
full-index scan. Both are tested with plain Node.

## Remove

```sh
omarchy plugin remove io.github.5d0tal1gat0r.stocks
```

## License

MIT
