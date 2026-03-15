# farm_tracker
This addon allows you to create lists with a name and location (gathered from your current position when created) that lists mouseover info from any entities with timers that you hover your mouse on.
This allows you to track the timers of entities such as plants in your farm, "illegal" farms, staged trade pack timers, and more.
This addon was made with Claude Sonnet 4.6.

How to use:

Launch the farm tracker with the button below the 'Esc' menu window. You can also enable a main UI persistent button in the Addon settings, this button can be shift-click dragged to reposition and the new position will be stored between sessions.

In the initial Farm Tracker window, create a farm with the '+ Add Farm' button. Creating a farm will tie it to the sextant coordinates of your current position.
After creating a farm, the list will automatically open. Hovering on an entity that contains mouseover info and a timer (such as a growing plant) will automatically add it to the list.
As it's easy to accidentally hover your mouse on something you didn't intend to enter into the list, the addon has a modifier key toggle and filter list features. 
Enabling 'Lock Filter' will prevent adding anything that isn't checked on in the 'Filters' list. When it is disabled, all new entity types/owners are added to both the farm list and the filters list.

The 'Share' button will write a text file to the share folder within this addon's folder that can be used to share the timers externally (e.g. on Discord). I've included a Python script that can be used to share these timers to a Discord channel automatically when it's opened and while it's running. 

Open the config.ini file in this addon's folder and substitute 'https://discord.com/api/webhooks/[your_webhook_here]' with your server's channel's webhook. [How to get a Discord channel webhook](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks)

The addon differentiates entities of the same name and owner by a 2 second or higher difference on the timer. This means things like trade packs after a server maintenance or plants replanted too quickly won't register as separate from each other.
