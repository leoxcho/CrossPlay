#!/usr/bin/env python3
"""Add identity-checked Steam artwork or game initials to existing AGTK wrappers; never launch games."""
import struct
import concurrent.futures, datetime, hashlib, json, pathlib, plistlib, re, shutil, subprocess, urllib.request, urllib.parse, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / 'Build/AGTKIconMigration'
WRAPPERS = pathlib.Path('/Volumes/M2/Users/leoxcho/Applications/AGTK Games')
ALIASES = {
 'AKIBAS TRIP Hellbound and Debriefed': "AKIBA'S TRIP: Hellbound & Debriefed", 'Besiege + The Splintered Sea DLC':'Besiege',
 'BorderlandsThePreSequel':'Borderlands: The Pre-Sequel', 'CatQuest':'Cat Quest', 'Cosmic Shake':'SpongeBob SquarePants: The Cosmic Shake', 'CrisTales':'Cris Tales',
 'DRAGON QUEST XI S Echoes of an Elusive Age DE':'DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition', 'Dark Souls 3':'DARK SOULS III', 'DeathStranding':'DEATH STRANDING',
 'Deus Ex HRDC': "Deus Ex: Human Revolution - Director's Cut", 'Deus Ex Mankind Divided':'Deus Ex: Mankind Divided',
 'Devil May Cry HD CollectionDevil May Cry HD':'Devil May Cry HD Collection', 'Disney Illusion Island SMAF':'Disney Illusion Island Starring Mickey & Friends',
 'Dissidia Final Fantasy NT':'DISSIDIA FINAL FANTASY NT Free Edition', 'Dragon Quest Heroes':'DRAGON QUEST HEROES Slime Edition', 'Dragonball Xenoverse Bundle Edition':'DRAGON BALL XENOVERSE',
 'DyingLight':'Dying Light', 'Faraway Director\'s Cut':"Faraway: Director's Cut", 'Ghostrunner2':'Ghostrunner 2', 'GhostwireTokyo':'Ghostwire: Tokyo',
 'Granblue FVR':'Granblue Fantasy Versus: Rising', 'Guacamelee2':'Guacamelee! 2', 'GuacameleeSTCE':'Guacamelee! Super Turbo Championship Edition',
 'HOTWHEELSUNLEASHED':'HOT WHEELS UNLEASHED', 'HogwartsLegacy':'Hogwarts Legacy',
 'Hyperdimension Neptunia Re Birth':'Hyperdimension Neptunia Re;Birth1', 'Hyperdimension Neptunia Re Birth 2':'Hyperdimension Neptunia Re;Birth2: Sisters Generation', 'Hyperdimension Neptunia Re Birth 3':'Hyperdimension Neptunia Re;Birth3 V Generation',
 'JustCause4':'Just Cause 4 Reloaded', 'KINGDOM HEARTS III':'KINGDOM HEARTS III + Re Mind (DLC)',
 'LEGO Horizon Adventures Digital Deluxe':'LEGO Horizon Adventures', 'LEGOStarWarsTSS':'LEGO Star Wars: The Skywalker Saga', 'LEGOBuildersJourney':"LEGO Builder's Journey", 'Lego2KDrive':'LEGO 2K Drive',
 'LegoBatman':'LEGO Batman: The Videogame', 'LegoBatman2':'LEGO Batman 2: DC Super Heroes', 'LegoBatman3':'LEGO Batman 3: Beyond Gotham', 'LEGO Star Wars - The Clone Wars':'LEGO Star Wars III - The Clone Wars',
 'Little Nightmares II Enhanced Edition':'Little Nightmares II', 'MARVEL vs CAPCOM FCAC':'MARVEL vs. CAPCOM Fighting Collection: Arcade Classics',
 'MarvelGOTG':"Marvel's Guardians of the Galaxy", 'Marvels Spider-Man Remastered':"Marvel’s Spider-Man Remastered", 'MetroLastLightRedux':'Metro: Last Light Redux', 'MortalShell':'Mortal Shell',
 'Neptunia Sisters VS Sisters Deluxe Edition':'Neptunia: Sisters VS Sisters', 'Ni No Kuni II Revenant  Kingdom':'Ni no Kuni II: Revenant Kingdom', 'NieR Automata Game of the YoRHa Edition':'NieR:Automata', 'NieR Replicant':'NieR Replicant ver.1.22474487139...',
 'Onee Chanbara ORIGIN':'Onee Chanbara ORIGIN', 'Plants Vs Zombies GOTY':'Plants vs. Zombies GOTY Edition', 'RAGE2':'RAGE 2', 'Redout2':'Redout 2', 'RedoutEnhancedEdition':'Redout: Enhanced Edition',
 'Resident Evil  Village':'Resident Evil Village', 'SBSP Titans of the Tide':'SpongeBob SquarePants: Titans of the Tide',
 'STAR OCEAN THE DIVINE FORCE DIGITAL DELUXE EDITION':'STAR OCEAN THE DIVINE FORCE', 'Season A Letter to the Future':'SEASON: A letter to the future',
 'Senran Kagura Bon Appetit':'SENRAN KAGURA Bon Appétit! - Full Course', 'Senran Kagura Burst Renewal':'SENRAN KAGURA Burst Re:Newal',
 'Shadow of Mordor':'Middle-earth: Shadow of Mordor', 'ShadowoftheTombRaider':'Shadow of the Tomb Raider: Definitive Edition', 'Shenmue3':'Shenmue III', 'SonicMania':'Sonic Mania',
 'Star Wars - Galactic Battlegrounds':'STAR WARS Galactic Battlegrounds Saga', 'The Outer Worlds SCE':"The Outer Worlds: Spacer’s Choice Edition", 'TinyTinasWonderlands':"Tiny Tina's Wonderlands", 'Tomb Raider IV VI Remastered':'Tomb Raider IV-VI Remastered',
 'Ultimate Ninja SC':'NARUTO SHIPPUDEN: Ultimate Ninja STORM 4', 'VALKYRIE ELYSIUM Deluxe Edition':'VALKYRIE ELYSIUM', 'Valkyrie Drive Bhikkhuni Complete Edition':'VALKYRIE DRIVE -BHIKKHUNI-', 'WolfensteinTNO':'Wolfenstein: The New Order', 'WorldWarZ':'World War Z', 'Zombie Army 4':'Zombie Army 4: Dead War'
}
def norm(s):
 s=re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', s)
 return ''.join(c for c in s.casefold() if c.isalnum())
def fetch(url):
 req=urllib.request.Request(url, headers={'User-Agent':'CrossPlay artwork matching/1.0'})
 with urllib.request.urlopen(req, timeout=20) as r:
  data=r.read(12_000_001)
  if len(data)>12_000_000: raise ValueError('Oversized artwork response')
  return data

def resolve(item):
 result=dict(item);query=ALIASES.get(item['name'],item['name']);result['query']=query
 try:
  response=json.loads(fetch('https://store.steampowered.com/api/storesearch/?'+urllib.parse.urlencode(dict(term=query,l='english',cc='US'))))
  candidates=response.get('items',[])
  exact=[x for x in candidates if norm(x['name'])==norm(query)]
  # Edition/remake ambiguity requires a corroborating local Steam ID, not a guessed search result.
  if item['name'] in ['Resident Evil 4','Star Wars - Battlefront 2','Tomb Raider','Mafia II'] and not item['localSteamIDs']:exact=[]
  if len(exact)!=1:
   result.update(status='initials',reason='No unique confirmed title/edition match',candidates=[dict(id=x['id'],name=x['name']) for x in candidates[:8]]);return result
  chosen=exact[0]
  if item['localSteamIDs'] and chosen['id'] not in item['localSteamIDs']:
   result.update(status='initials',reason='Local Steam ID disagrees with title match',candidates=[dict(id=chosen['id'],name=chosen['name'])]);return result
  details=json.loads(fetch('https://store.steampowered.com/api/appdetails?'+urllib.parse.urlencode(dict(appids=chosen['id'],l='english')))).get(str(chosen['id']),{})
  app=details.get('data',{})
  if not details.get('success') or app.get('steam_appid')!=chosen['id'] or norm(app.get('name',''))!=norm(query):raise ValueError('App details identity mismatch')
  image=app['header_image']
  if urllib.parse.urlparse(image).scheme!='https':raise ValueError('Non-HTTPS artwork')
  data=fetch(image);path=WORK/'Artwork'/f"{chosen['id']}.image";path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
  result.update(status='artwork',steamAppID=chosen['id'],matchedTitle=app['name'],source=f"https://store.steampowered.com/app/{chosen['id']}/",image=str(path))
 except Exception as error:result.update(status='initials',reason=str(error))
 return result

def payload_hash(binary):
 data=binary.read_bytes()
 assert data[:4]==b'\xcf\xfa\xed\xfe', 'Expected native ARM64 Mach-O launcher'
 ncmds=struct.unpack_from('<I',data,16)[0];cursor=32;digest=hashlib.sha256()
 for _ in range(ncmds):
  cmd,size=struct.unpack_from('<II',data,cursor)
  if cmd==0x19:
   count=struct.unpack_from('<I',data,cursor+64)[0]
   for i in range(count):
    offset=cursor+72+i*80
    sectionSize=struct.unpack_from('<Q',data,offset+40)[0];fileOffset=struct.unpack_from('<I',data,offset+48)[0];flags=struct.unpack_from('<I',data,offset+64)[0]
    if fileOffset and sectionSize and flags&0xff not in (1,12,18):
     digest.update(data[offset:offset+32]);digest.update(data[fileOffset:fileOffset+sectionSize])
  cursor+=size
 return digest.hexdigest()

def apply(item,backup):
 app=pathlib.Path(item['app']);profile=app/'Contents/Resources/AGTKProfile.plist';infoPath=app/'Contents/Info.plist'
 originalInfo=plistlib.loads(infoPath.read_bytes());originalProfile=profile.read_bytes();record=plistlib.loads(originalProfile)
 assert record.get('Executable')==item['executable'], 'Game profile changed since inventory'
 assert originalInfo.get('CFBundleExecutable')=='AGTKGameLauncher', 'Unexpected wrapper executable'
 executable=app/'Contents/MacOS/AGTKGameLauncher';sha=hashlib.sha256(executable.read_bytes()).hexdigest();payload=payload_hash(executable)
 stage=app.parent/('.CrossPlay-Icon-'+uuid.uuid4().hex+'.app')
 try:
  shutil.copytree(app,stage,symlinks=True)
  resources=stage/'Contents/Resources';icon=resources/'GameIcon.icns'
  subprocess.run([str(ROOT/'CrossPlay.app/Contents/MacOS/CrossPlay'),'--make-game-icon',item.get('image','-'),str(icon),item['name']],check=True,stdout=subprocess.DEVNULL)
  plist=dict(originalInfo);plist['CFBundleIconFile']='GameIcon.icns'
  (stage/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
  (resources/'GameArtwork.json').write_text(json.dumps({k:item[k] for k in ['name','executable','status','steamAppID','matchedTitle','source','reason'] if k in item},indent=2))
  assert (resources/'AGTKProfile.plist').read_bytes()==originalProfile
  assert hashlib.sha256((stage/'Contents/MacOS/AGTKGameLauncher').read_bytes()).hexdigest()==sha
  for args in [['--force','--sign','-','--preserve-metadata=identifier,entitlements,flags,runtime',str(stage)],['--verify','--deep','--strict',str(stage)]]:subprocess.run(['codesign',*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  assert payload_hash(stage/'Contents/MacOS/AGTKGameLauncher')==payload, 'Launcher payload changed during signing'
  assert (stage/'Contents/Resources/AGTKProfile.plist').read_bytes()==originalProfile
  saved=backup/app.name;shutil.move(str(app),str(saved))
  try:shutil.move(str(stage),str(app))
  except Exception:shutil.move(str(saved),str(app));raise
  subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  return dict(app=str(app),status=item['status'],steamAppID=item.get('steamAppID'),matchedTitle=item.get('matchedTitle'),originalExecutableSHA256=sha,launcherPayloadSHA256=payload,profileSHA256=hashlib.sha256(originalProfile).hexdigest(),backup=str(saved),verified=True)
 finally:
  if stage.exists():shutil.rmtree(stage)

if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser();p.add_argument('--apply',action='store_true');p.add_argument('--resolve',action='store_true');a=p.parse_args()
 inventory=json.loads((WORK/'inventory.json').read_text())
 if a.resolve:
  with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:results=list(pool.map(resolve,[x for x in inventory if not x['hasIcon'] and x['profile']]))
  (WORK/'matches.json').write_text(json.dumps(results,indent=2))
  print(json.dumps(dict(total=len(results),artwork=sum(x['status']=='artwork' for x in results),initials=sum(x['status']=='initials' for x in results))),flush=True)
 if a.apply:
  results=json.loads((WORK/'matches.json').read_text());backup=ROOT/'Build/Checkpoints'/('AGTK-Icons-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));backup.mkdir(parents=True)
  applied=[]
  for i,item in enumerate(results):
   try:applied.append(apply(item,backup))
   except Exception as error:applied.append(dict(app=item['app'],verified=False,error=str(error)))
   (WORK/'applied.json').write_text(json.dumps(applied,indent=2))
   if (i+1)%25==0:print(f'Processed {i+1}/{len(results)}',flush=True)
  print(json.dumps(dict(updated=sum(x['verified'] for x in applied),failed=sum(not x['verified'] for x in applied),backup=str(backup))),flush=True)
