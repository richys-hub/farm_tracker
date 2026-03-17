# Farm Tracker

This addon allows you to create lists with a name and location (gathered from your current position when created) that lists mouseover info from any entities with timers that you hover your mouse on.

This allows you to track the timers of entities such as plants in your farm, "illegal" farms, staged trade pack timers, and more.

> This addon was made with Claude Sonnet 4.6.

---

## Getting Started

Launch the farm tracker with the button below the 'Esc' menu window. You can also enable a main UI persistent button in the Addon settings — this button can be shift-click dragged to reposition and the new position will be stored between sessions.

In the initial Farm Tracker window, create a farm with the **+ Add Farm** button. Creating a farm will tie it to the sextant coordinates of your current position. After creating a farm, the list will automatically open. Hovering on an entity that contains mouseover info and a timer (such as a growing plant) will automatically add it to the list.

---

## Modifier Key & Filters

As it's easy to accidentally hover your mouse on something you didn't intend to enter into the list, the addon has a modifier key toggle and filter list features.

Enabling **Lock Filter** will prevent adding anything that isn't checked on in the **Filters** list. When it is disabled, all new entity types/owners are added to both the farm list and the filters list.

---

## Sharing to Discord

The **Share** button will write a text file to the share folder within this addon's folder that can be used to share the timers externally (e.g. on Discord). You have two options on how to share them onto a Discord channel:

**Option 1 — Python executable (.exe)**
Build the `farm_share_poster.py` Python script into an executable. For your security, I can't include the built .exe file into the addon install. [How to convert Python Script to .exe File](https://www.geeksforgeeks.org/python/convert-python-script-to-exe-file/)

The .exe will post the share files in the `share/` folder to your Discord channel automatically when it's opened and while it's running.

**Option 2 — PowerShell script**
Run `farm_share_poster.ps1` with PowerShell (Right Click → Run with PowerShell) *after* creating the share file with the addon in-game. It will post all shared farms to your Discord channel.

You may need to enable PowerShell script execution on your PC: [How to enable.](https://powershellcommands.com/how-to-enable-execution-of-powershell-scripts)

### Discord Webhook Setup

To select which Discord server channel will receive the farm share messages, open the `config.ini` file in this addon's folder and substitute `https://discord.com/api/webhooks/[your_webhook_here]` with your server's channel's webhook. [How to get a Discord channel webhook](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks)

---

## Individual Timers

By default, the addon only shares earliest and latest timers on the Discord post. If you wish to have each individual timer listed on the Discord post, simply expand the list of timers for a particular entry by enabling the checkbox to the left of its name.

---

## Notes

The addon differentiates entities of the same name and owner by a 2 second or higher difference on the timer. This means things like trade packs after a server maintenance or plants replanted too quickly won't register as separate from each other.
