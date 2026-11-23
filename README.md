# Stocks for Omarchy

A Wall-Street-style ticker tape for the Omarchy Quattro bar. The tape scrolls
your symbols (`AAPL 305.59 ▲0.42%  •  NVDA …`) in the theme's green/red; click
it for a panel with sparklines, a detail chart with range selector, key stats
and a currency switch. Live quote prices come from Robinhood, including its
latest non-regular-hours trade when newer than the last regular-hours trade.
Historical charts and FX conversion rates come from Yahoo Finance.

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
| panel | `Open on Yahoo Finance ↗` | open the selected symbol in your browser |

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
| `symbols` | `["AAPL","NVDA","SPCX","GOOGL"]` | Robinhood-supported stock symbols; a comma-separated string also works |
| `refreshMinutes` | `5` | quote refresh interval (minimum 1) |
| `tickerWidth` | `180` | tape width in px (minimum 80) |
| `scrollSpeed` | `20` | tape speed in px/s; `0` = static |
| `compact` | `false` | drop the price from the tape |
| `chartRange` | `1d` | one of `1d 5d 1mo 6mo 1y` (the panel chips set this) |
| `currency` | `""` (native) | show every price in this currency, e.g. `EUR` (the panel chip sets this) |
| `currencies` | `["USD","EUR","GBP","JPY","CHF"]` | what the currency chip cycles through |
| `upColor` / `downColor` | theme `green` / `red` | override the tints with a hex color, e.g. `"#a6e3a1"` |

Symbols without Robinhood quotes show an error in the panel and are left out
of the tape. Colors follow the current theme's `colors.toml`; themes without a
`green` get a neutral fallback.

The quote endpoint may not return every symbol supported by Yahoo Finance.
Chart history and currency conversion still use Yahoo Finance.

## Develop

Clone this repository (or your fork), then from its root:

```sh
node --test test/model.test.js                              # Model.js unit tests
qmllint -I /usr/share/omarchy/shell Panel.qml
omarchy plugin validate "$PWD"
omarchy plugin add "$PWD" --enable                          # installs a clone into ~/.config/omarchy/plugins/
rsync -a --delete --exclude .git ./ ~/.config/omarchy/plugins/io.github.5d0tal1gat0r.stocks/
omarchy restart shell                                       # QML is cached per shell process; a restart loads the edit
qs log -p /usr/share/omarchy/shell --tail 100               # shell log
```

`Model.js` holds every piece of logic that does not need QML (parsing, formatting,
conversion, chart geometry) so it can be tested with plain Node.

## Remove

```sh
omarchy plugin remove io.github.5d0tal1gat0r.stocks
```

## License

MIT
