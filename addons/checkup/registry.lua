-- The add-ons in this package, for //ck addons. Edit the status column as add-ons are confirmed in game.
return {
  {id="bags", kind="addon", goal="qol", status="offline", verified="-", role="display", version="0.2.1", purpose="Bag fullness", module="gear", public="launch", requires="", uses="boxtheme"},
  {id="buffbox", kind="addon", goal="qol", status="proven", verified="-", role="display", version="0.10.0", purpose="Buffs, food, rolls, Ionis (reads atlas-generated data)", module="gear", public="launch", requires="", uses="boxtheme"},
  {id="timers", kind="addon", goal="qol", status="offline", verified="-", role="display", version="0.1.5", purpose="Recasts and Scholar stratagem charges", module="gear", public="launch", requires="", uses="boxtheme"},
  {id="battlelines", kind="addon", goal="gear", status="offline", verified="-", role="display", version="0.7.3", purpose="Damage meter", module="gear", public="launch", requires="", uses="boxtheme"},
  {id="boxtheme", kind="addon", goal="qol", status="offline", verified="-", role="display-core", version="0.5.8", purpose="Themed box backgrounds, locks, accents", module="gear", public="launch", requires="", uses=""},
  {id="storyguide", kind="addon", goal="qol", status="offline", verified="-", role="display", version="0.18.2", purpose="Mission tracker box (//sg): your place in each storyline", module="story", public="launch", requires="", uses=""},
  {id="charsync", kind="addon", goal="gear", status="proven", verified="2026-10-04", role="recorder-snapshot", version="0.3.27", purpose="Whole-character snapshot; since 0.2.0 also points.tsv, rema.tsv, currencies.tsv (replaced points and rema; 0.2.0 offline-tested)", module="gear", public="launch", requires="", uses=""},
  {id="checkup", kind="addon", goal="qol", status="offline", verified="-", role="meta", version="0.5.11", purpose="Setup checklist and recorder health", module="gear", public="launch", requires="", uses="boxtheme"},
  {id="combatlog", kind="addon", goal="gear", status="proven", verified="-", role="recorder-event", version="1.4.3", purpose="Combat recorder + live box (schema v1 writer 1.0.x is offline-tested)", module="gear", public="launch", requires="", uses="boxtheme"},
}
