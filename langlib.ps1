# =============================================================================
#  langlib.ps1 -- user-visible text, in the language of Windows
#
#  Every string a person actually reads lives here, not scattered through the
#  scripts. Dot-source this file and use T:
#
#      . (Join-Path $Root 'langlib.ps1')
#      $mi.Text = T 'menu.compact'
#
#  The language comes from the Windows display language (Get-UICulture), so the
#  HUD follows the system without a setting of its own. Anything that is not
#  Dutch falls back to English -- an unknown language is better served by
#  English than by Dutch.
#
#  The CYD gets its text from here too: session-api.ps1 puts the labels in the
#  header line of /cyd.txt. That way the display follows the language of the PC
#  and the sketch needs no table of its own, so switching language does not
#  mean reflashing.
#
#  Adding a language: copy the 'en' block, translate the values, and add it to
#  $LANGS. Keys missing from a block fall through to English.
# =============================================================================

$script:LANGS = @{

    en = @{
        # ---- window and header
        'app.title'            = 'Claude sessions'
        'app.header'           = 'CLAUDE SESSIONS'
        'hud.shortcutDesc'     = 'Claude sessions HUD'

        # ---- session states
        'state.attention'      = 'Needs you'
        'state.active'         = 'Working'
        'state.done'           = 'Done'
        'state.ended'          = 'Finished'
        'state.unknown'        = 'Unknown'
        'state.snoozeUntil'    = 'Snoozed until {0}'

        # ---- short labels for the small display (keep these short!)
        'cyd.attention'        = 'NEEDS YOU'
        'cyd.active'           = 'WORKING'
        'cyd.done'             = 'DONE'
        'cyd.offline'          = 'NO CONNECTION'
        'cyd.idle'             = 'CLAUDE IDLE'
        'cyd.waitingCount'     = '{0} NEED{1} YOU'
        'cyd.activeCount'      = '{0} WORKING'
        'cyd.noSessions'       = 'No active sessions.'
        'cyd.noAnswer'         = 'No answer from {0}'
        'cyd.checkApi'         = 'Is the API running? Is this address right?'
        'cyd.holdToSetup'      = 'Hold the top bar 2s to set up'

        # ---- empty states
        'empty.none'           = 'No active sessions.'
        'empty.filtered'       = 'No session needs you.'
        'empty.filterHint'     = 'The "needs me only" filter is on - right-click to turn it off.'
        'empty.beacons'        = '{0} beacons known'

        # ---- menu
        'menu.topmost'         = 'Always on top'
        'menu.compact'         = 'Compact rows'
        'menu.onlyAttention'   = 'Only sessions that need me (hides the rest)'
        'menu.dashboard'       = 'Open dashboard'
        'menu.address'         = 'Address of this PC'
        'menu.addressWith'     = 'Address of this PC:  {0}'
        'menu.addressNone'     = 'Address of this PC:  no network'
        'menu.addressTip'      = 'Click to copy'
        'menu.statusPage'      = 'Open status page'
        'menu.cracktro'        = 'Cracktro on the display'
        'menu.releasePort'     = 'Release the USB port (to flash)'
        'menu.about'           = 'About Claude Sessions Monitor'

        # ---- about and updating
        'about.title'          = 'About Claude Sessions Monitor'
        'about.by'             = 'made by Dimmy of OmegaWare'
        'about.tagline'        = 'See which of your Claude Code sessions is waiting for you.'
        'about.installed'      = 'Installed'
        'about.latest'         = 'Latest'
        'about.checking'       = 'checking...'
        'about.upToDate'       = 'up to date'
        'about.newer'          = 'update available'
        'about.offline'        = 'could not reach GitHub'
        'about.kindGit'        = 'git checkout - updating runs git pull'
        'about.kindCopy'       = 'installed copy - updating fetches the release'
        'about.update'         = 'Update'
        'about.whatsNew'       = "What's new"
        'about.display'        = 'Display'
        'about.dispNone'       = 'not connected'
        'about.dispOld'        = 'newer firmware available'
        'about.dispCurrent'    = 'up to date'
        'about.flash'          = 'Flash the display'
        'about.repo'           = 'Source on GitHub'
        'about.close'          = 'Close'
        'upd.busy'             = 'Updating...'
        'upd.done'             = 'Updated. Restarting.'
        'upd.dirty'            = 'This is a git checkout with uncommitted changes. Commit or stash them first - an update must never throw your work away.'
        'upd.gitFailed'        = 'git pull did not succeed:'
        'upd.noAsset'          = 'That release has no ClaudeDeck.zip attached.'
        'upd.noInstaller'      = 'No install.ps1 found in the downloaded package.'
        'upd.installFailed'    = 'The installer reported a problem.'
        'upd.downloadFailed'   = 'Downloading failed:'
        'menu.released'        = 'USB port'
        'menu.releasedBody'    = 'Released for a minute. The bridge picks it up again by itself.'
        'menu.autostart'       = 'Start when I log in'
        'menu.restart'         = 'Restart HUD'
        'menu.quit'            = 'Quit HUD'

        # ---- notifications
        'notify.waiting'       = 'Claude needs you: {0}'
        'notify.noWindow'      = 'No window found'
        'notify.noWindowBody'  = 'Could not find the terminal window for this session.'
        'notify.pickWindow'    = 'Pick a window'

        # ---- web status page
        'web.title'            = 'Claude sessions'
        'web.summary'          = 'Claude sessions - {0} need you - {1} working'
        'web.updated'          = 'updated {0}'
        'web.tapHint'          = 'tap a row to bring that window to the front'

        # ---- errors returned to the display and the web page
        'err.noActions'        = 'error: no actions.json'
        'err.buttonUnset'      = 'error: button {0} is not configured'
        'err.noWindow'         = 'error: no window found'
        'err.noKeys'           = 'error: no keys configured'
        'err.windowNotActive'  = 'error: window did not come to the front'
        'err.windowNotRaised'  = 'error: found it, but Windows would not raise it'
        'err.snoozeFailed'     = 'error: snooze failed'
        'err.noCommand'        = 'error: no command configured'
        'err.startFailed'      = 'error: could not start it'
        'err.noPath'           = 'error: no path configured'
        'err.noSession'        = 'error: no such session'
        'err.badToken'         = 'error: wrong token'
        'err.needsAttention'   = 'error: {0} only works when that session is waiting'
        'ok.action'            = 'ok {0}'

        # ---- default button labels (actions.json refers to these by labelKey)
        'action.approve'       = 'Approve'
        'action.reject'        = 'Reject'
        'action.snooze'        = 'Snooze {0} min'
        'action.focus'         = 'Go to window'
    }

    nl = @{
        'app.title'            = 'Claude-sessies'
        'app.header'           = 'CLAUDE-SESSIES'
        'hud.shortcutDesc'     = 'Claude-sessies HUD'

        'state.attention'      = 'Aandacht nodig'
        'state.active'         = 'Actief'
        'state.done'           = 'Klaar'
        'state.ended'          = 'Afgerond'
        'state.unknown'        = 'Onbekend'
        'state.snoozeUntil'    = 'Snooze tot {0}'

        'cyd.attention'        = 'WACHT OP JOU'
        'cyd.active'           = 'ACTIEF'
        'cyd.done'             = 'KLAAR'
        'cyd.offline'          = 'GEEN VERBINDING'
        'cyd.idle'             = 'CLAUDE RUSTIG'
        'cyd.waitingCount'     = '{0} WACHT{1} OP JOU'
        'cyd.activeCount'      = '{0} ACTIEF'
        'cyd.noSessions'       = 'Geen actieve sessies.'
        'cyd.noAnswer'         = 'Geen antwoord van {0}'
        'cyd.checkApi'         = 'Draait de API op je pc? Klopt dit adres?'
        'cyd.holdToSetup'      = 'Bovenbalk 2 sec vasthouden = instellen'

        'empty.none'           = 'Geen actieve sessies.'
        'empty.filtered'       = 'Geen sessie vraagt aandacht.'
        'empty.filterHint'     = 'Filter "alleen aandacht nodig" staat aan - rechtermuis om hem uit te zetten.'
        'empty.beacons'        = '{0} beacons bekend'

        'menu.topmost'         = 'Altijd bovenop'
        'menu.compact'         = 'Compacte rijen'
        'menu.onlyAttention'   = 'Alleen aandacht nodig (verbergt de rest)'
        'menu.dashboard'       = 'Dashboard openen'
        'menu.address'         = 'Adres van deze pc'
        'menu.addressWith'     = 'Adres van deze pc:  {0}'
        'menu.addressNone'     = 'Adres van deze pc:  geen netwerk'
        'menu.addressTip'      = 'Klik om te kopieren'
        'menu.statusPage'      = 'Statuspagina openen'
        'menu.cracktro'        = 'Cracktro op het schermpje'
        'menu.releasePort'     = 'USB-poort vrijgeven (om te flashen)'
        'menu.about'           = 'Over Claude Sessions Monitor'

        'about.title'          = 'Over Claude Sessions Monitor'
        'about.by'             = 'made by Dimmy of OmegaWare'
        'about.tagline'        = 'Zie welke van je Claude Code-sessies op je wacht.'
        'about.installed'      = 'Geinstalleerd'
        'about.latest'         = 'Nieuwste'
        'about.checking'       = 'kijken...'
        'about.upToDate'       = 'up-to-date'
        'about.newer'          = 'update beschikbaar'
        'about.offline'        = 'kon GitHub niet bereiken'
        'about.kindGit'        = 'git-clone - bijwerken doet git pull'
        'about.kindCopy'       = 'geinstalleerde kopie - bijwerken haalt de release'
        'about.update'         = 'Bijwerken'
        'about.whatsNew'       = 'Wat is er nieuw'
        'about.display'        = 'Schermpje'
        'about.dispNone'       = 'niet verbonden'
        'about.dispOld'        = 'nieuwere firmware beschikbaar'
        'about.dispCurrent'    = 'up-to-date'
        'about.flash'          = 'Schermpje flashen'
        'about.repo'           = 'Broncode op GitHub'
        'about.close'          = 'Sluiten'
        'upd.busy'             = 'Bijwerken...'
        'upd.done'             = 'Bijgewerkt. Opnieuw starten.'
        'upd.dirty'            = 'Dit is een git-clone met wijzigingen die nog niet vastgelegd zijn. Leg die eerst vast of zet ze weg - een update mag jouw werk nooit weggooien.'
        'upd.gitFailed'        = 'git pull is niet gelukt:'
        'upd.noAsset'          = 'Bij die release hangt geen ClaudeDeck.zip.'
        'upd.noInstaller'      = 'Geen install.ps1 gevonden in het gedownloade pakket.'
        'upd.installFailed'    = 'De installer meldde een probleem.'
        'upd.downloadFailed'   = 'Downloaden is mislukt:'
        'menu.released'        = 'USB-poort'
        'menu.releasedBody'    = 'Een minuut vrijgegeven. De bridge pakt hem daarna zelf weer op.'
        'menu.autostart'       = 'Starten bij inloggen'
        'menu.restart'         = 'HUD herstarten'
        'menu.quit'            = 'HUD afsluiten'

        'notify.waiting'       = 'Claude wacht op je: {0}'
        'notify.noWindow'      = 'Geen venster gevonden'
        'notify.noWindowBody'  = 'Kon het terminalvenster van deze sessie niet vinden.'
        'notify.pickWindow'    = 'Vensterkeuze'

        'web.title'            = 'Claude-sessies'
        'web.summary'          = 'Claude-sessies - {0} wachten - {1} actief'
        'web.updated'          = 'bijgewerkt {0}'
        'web.tapHint'          = 'tik een rij aan om dat venster naar voren te halen'

        'err.noActions'        = 'fout: geen actions.json'
        'err.buttonUnset'      = 'fout: knop {0} is niet ingesteld'
        'err.noWindow'         = 'fout: geen venster gevonden'
        'err.noKeys'           = 'fout: geen toetsen ingesteld'
        'err.windowNotActive'  = 'fout: venster kwam niet naar voren'
        'err.windowNotRaised'  = 'fout: gevonden, maar Windows liet hem niet voor'
        'err.snoozeFailed'     = 'fout: snooze mislukt'
        'err.noCommand'        = 'fout: geen command ingesteld'
        'err.startFailed'      = 'fout: starten mislukt'
        'err.noPath'           = 'fout: geen path ingesteld'
        'err.noSession'        = 'fout: die sessie bestaat niet'
        'err.badToken'         = 'fout: verkeerd token'
        'err.needsAttention'   = 'fout: {0} kan alleen als die sessie wacht'
        'ok.action'            = 'ok {0}'

        'action.approve'       = 'Goedkeuren'
        'action.reject'        = 'Weigeren'
        'action.snooze'        = 'Snooze {0} min'
        'action.focus'         = 'Naar het venster'
    }
}

# Which language are we speaking? Overridable with -Lang / $env:CLAUDE_DECK_LANG,
# which is what makes the other language testable without changing Windows.
function Get-DashLang {
    if ($env:CLAUDE_DECK_LANG) {
        $v = $env:CLAUDE_DECK_LANG.ToLower()
        if ($script:LANGS.ContainsKey($v)) { return $v }
    }
    try {
        $code = (Get-UICulture).TwoLetterISOLanguageName.ToLower()
        if ($script:LANGS.ContainsKey($code)) { return $code }
    } catch { }
    return 'en'
}

$script:DashLang = Get-DashLang

<#
  T 'key'              -> the string
  T 'key' @('a','b')   -> the string with {0} and {1} filled in

  An unknown key returns the key itself between brackets. That is deliberate:
  a visible [menu.typo] on screen gets fixed, a silent empty string does not.
#>
function T([string]$key, $args_ = @()) {
    $tab = $script:LANGS[$script:DashLang]
    $val = $null
    if ($tab -and $tab.ContainsKey($key)) { $val = $tab[$key] }
    if ($null -eq $val) {
        $en = $script:LANGS['en']
        if ($en.ContainsKey($key)) { $val = $en[$key] }
    }
    if ($null -eq $val) { return "[$key]" }
    if ($args_ -and @($args_).Count) { return ([string]::Format($val, [object[]]@($args_))) }
    return $val
}
