# swiftSTOCKS

swiftSTOCKS is a lightweight, personal portfolio tracker that retrieves live market data and provides an at-a-glance view of your holdings, current market value, and unrealized gains or losses.

This project is intended for personal use. It is not designed to replace a professional portfolio management platform or financial planning application. While every effort has been made to provide accurate information, market data may be delayed or unavailable, and no guarantees are made regarding the accuracy or completeness of the data. Always verify financial information before making investment decisions.

<img width="989" height="611" alt="image" src="https://github.com/user-attachments/assets/59ce928c-356d-4975-bfb3-45bbe5f243b1" />

---

## What It Does

- Tracks a personal stock portfolio with purchase cost and share count
- Pulls live market prices from a public data source
- Calculates current value, gain/loss in dollars, and gain/loss as a percentage per holding
- Shows portfolio totals and indicates market open/closed status
- Flags each position as LIVE or DELAYED depending on data availability

---

## Main Workspace

```
PORTFOLIO: 3 Positions Held                           ● MARKET CLOSED
Last Data Pull: 09:33 PM  [R] to refresh             ● Gain/Loss: +$20,724.7 (+188.23%)
```

The grid shows position number, company name, ticker symbol, shares held, cost basis, current market price, total value, gain/loss in dollars, gain/loss percentage, and data type (LIVE or DELAYED).

---

## Key Shortcuts

### Workspace
| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate positions |
| `ENTER` or `1-9` | View position detail |
| `A` | Add new position |
| `R` | Refresh market data |
| `/` | Search positions |
| `D` | Delete selected position |
| `U` | Utilities menu |

### Position Detail Screen
| Key | Action |
|-----|--------|
| `E` | Edit position |
| `D` | Delete position |
| `ESC` | Back to workspace |

---

## Adding a Position

Press `A` from the workspace. You will be prompted for:

1. **Company Name** — full name (e.g. `Company X Technologies Inc.`)
2. **Ticker Symbol** — exchange symbol (e.g. `xxxx`)
3. **Shares** — number of shares held
4. **Cost Basis** — your average purchase price per share

swiftSTOCKS fetches the current price immediately after adding.

---

## Market Data

- Press `R` at any time to refresh all prices
- The status line shows the time of the last data pull
- Market open/closed status is shown in the top right

---

## Portfolio Totals

The bottom of the grid shows aggregate totals across all positions:

```
TOTALS                                    31,735.2    +$20,724.7    +188.23%
```

This gives you your total portfolio value, total gain/loss in dollars, and overall return percentage at a glance.

---

## Utilities

| Option | Description |
|--------|-------------|
| Backup Portfolio | Creates a backup of your positions |
| Restore Portfolio | Restores from a previous backup |
| Export CSV | Exports positions to CSV |
| Delete All Positions | Wipes all portfolio data |

---

## Tips

- Use `R` to refresh before making any decisions — prices can move quickly during market hours
- The cost basis is your average purchase price, not the price of each individual lot
- swiftSTOCKS tracks unrealized gain/loss only — it does not track dividends or realized gains from sales
