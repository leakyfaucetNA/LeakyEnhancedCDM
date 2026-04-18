# Features

## Auras
* Glow External frames
* Custom Event Firings (for use with WA)
* Sounds
    * When Aura is Active
    * When Aura fades

## Cooldowns
* Glow External frames
* Custom Even Firing (for use with WA)
* Fire Sounds
    * When on Cooldown
    * When Ready


## All
* Load conditions
* Each spec has its own "config" of what auras do what. And should be saved spec specific

* Each Class can see the setup for each of its specs but they wont be active. This is just to clone or copy it into the current spec



## Modules

### Auras.lua
Contains all the functions and calls for auras to trigger. Also contains the AuraInstanceID tracking methods for the CDM Auras

### Cooldowns.lua
Contains all the functions for the Cooldowns in the CDM and handlers for those events.

### Events.lua
Contains all the custom event firing code. When an aura is applied it fires LEC_AURA_APPLIED and the payload is the aurainstanceID, nonsecret spellid, nonsecret override spell id.

Similarly when aura is removed it fires a LEC_AURA_REMOVED event. 

Basically copies what happens in the old LeakyAuras event handling but also includes options to fire an event for Cooldowns so that other addons can see those events. 

### glows.lua
Similar to the leakaura glows, is the glow handling to avoid tainting

### sounds.lua
Is the handler for firing sounds. 