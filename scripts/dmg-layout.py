"""Write Finder layout directly, without depending on Finder's delayed preference flush."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias
root = Path(sys.argv[1])
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowTabView': False,
        'ShowPathbar': False, 'ShowSidebar': False, 'SidebarWidth': 0,
        'WindowBounds': '{{120, 120}, {720, 488}}',
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundColorRed': 0.1, 'backgroundColorGreen': 0.05, 'backgroundColorBlue': 0.2,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
        'backgroundImageAlias': Alias.for_file(str(root / '.background/installer.png')).to_bytes(),
        'iconSize': 160.0, 'textSize': 14.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['icvl'] = ('type', 'icnv')
    store['Animated Setup.app']['Iloc'] = (360, 225)
