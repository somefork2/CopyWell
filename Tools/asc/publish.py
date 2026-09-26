#!/usr/bin/env python3
"""Publishes a CopyWell update to App Store Connect, one step at a time.

    python3 Tools/asc/publish.py version          create (or find) the version
    python3 Tools/asc/publish.py texts            name, subtitle, description… in every locale
    python3 Tools/asc/publish.py shots [locale…]  replace the screenshots
    python3 Tools/asc/publish.py build            attach the build, review notes, contact
    python3 Tools/asc/publish.py status           what is there now
    python3 Tools/asc/publish.py submit           send it for review — only when asked

Every step can be run again: it updates what exists and creates what does not.
Texts come from docs/store/metadata/<lang>.json, screenshots from
docs/screenshots/store/<lang>/, the review notes from docs/review-notes.txt.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import ASC  # noqa: E402

APP_ID = "6813555231"
VERSION = "1.1.0"
BUILD = "37"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# App language → the App Store locales it serves. English, French and Spanish
# also cover their regional listings, which reuse the base language's text.
LOCALES = {
    "en": ["en-US", "en-GB", "en-AU", "en-CA"], "fr": ["fr-FR", "fr-CA"], "es": ["es-ES", "es-MX"],
    "ar": ["ar-SA"], "bn": ["bn-BD"], "ca": ["ca"], "cs": ["cs"], "da": ["da"], "de": ["de-DE"], "el": ["el"],
    "fi": ["fi"], "gu": ["gu-IN"], "he": ["he"], "hi": ["hi"], "hr": ["hr"], "hu": ["hu"], "id": ["id"],
    "it": ["it"], "ja": ["ja"], "kn": ["kn-IN"], "ko": ["ko"], "ml": ["ml-IN"], "mr": ["mr-IN"], "ms": ["ms"],
    "nb": ["no"], "nl": ["nl-NL"], "or": ["or-IN"], "pa": ["pa-IN"], "pl": ["pl"], "pt-BR": ["pt-BR"],
    "pt-PT": ["pt-PT"], "ro": ["ro"], "ru": ["ru"], "sk": ["sk"], "sl": ["sl-SI"], "sv": ["sv"], "ta": ["ta-IN"],
    "te": ["te-IN"], "th": ["th"], "tr": ["tr"], "uk": ["uk"], "ur": ["ur-PK"], "vi": ["vi"],
    "zh-Hans": ["zh-Hans"], "zh-Hant": ["zh-Hant"],
}
LOCALE_TO_LANG = {locale: lang for lang, locales in LOCALES.items() for locale in locales}

asc = ASC()


def metadata(lang):
    with open(os.path.join(REPO, "docs", "store", "metadata", f"{lang}.json"), encoding="utf-8") as f:
        return json.load(f)


def find_version():
    for version in asc.get_all(f"/v1/apps/{APP_ID}/appStoreVersions", **{"filter[platform]": "MAC_OS"}):
        if version["attributes"]["versionString"] == VERSION:
            return version
    return None


def live_version():
    for version in asc.get_all(f"/v1/apps/{APP_ID}/appStoreVersions", **{"filter[platform]": "MAC_OS"}):
        if version["attributes"].get("appStoreState") == "READY_FOR_SALE":
            return version
    return None


def editable_app_info():
    infos = asc.get_all(f"/v1/apps/{APP_ID}/appInfos")
    for info in infos:
        state = info["attributes"].get("appStoreState") or info["attributes"].get("state")
        if state not in ("READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"):
            return info
    return infos[0]


def step_version():
    version = find_version()
    if version:
        print(f"version {VERSION} exists: {version['id']} ({version['attributes'].get('appStoreState')})")
        return version
    version = asc.post("/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": "MAC_OS", "versionString": VERSION},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
    }})["data"]
    print(f"created version {VERSION}: {version['id']}")
    return version


def step_texts():
    version = find_version() or sys.exit("run `version` first")
    info = editable_app_info()
    english = metadata("en")

    # Name and subtitle live on the app info; description and the rest on the version.
    info_locs = {l["attributes"]["locale"]: l for l in asc.get_all(f"/v1/appInfos/{info['id']}/appInfoLocalizations")}
    privacy_url = next((l["attributes"].get("privacyPolicyUrl") for l in info_locs.values()
                        if l["attributes"].get("privacyPolicyUrl")), None)
    version_locs = {l["attributes"]["locale"]: l for l in
                    asc.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")}
    template = version_locs.get("en-US", {}).get("attributes", {})
    support_url, marketing_url = template.get("supportUrl"), template.get("marketingUrl")

    for locale, lang in LOCALE_TO_LANG.items():
        meta = metadata(lang)
        info_attrs = {"name": meta["name"], "subtitle": meta["subtitle"]}
        if privacy_url:
            info_attrs["privacyPolicyUrl"] = privacy_url
        if locale in info_locs:
            asc.patch(f"/v1/appInfoLocalizations/{info_locs[locale]['id']}", {"data": {
                "type": "appInfoLocalizations", "id": info_locs[locale]["id"], "attributes": info_attrs}})
        else:
            asc.post("/v1/appInfoLocalizations", {"data": {
                "type": "appInfoLocalizations", "attributes": {"locale": locale, **info_attrs},
                "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}})

        version_attrs = {
            "description": meta["description"], "keywords": meta["keywords"],
            "promotionalText": meta["promotionalText"], "whatsNew": meta["whatsNew"],
        }
        if support_url:
            version_attrs["supportUrl"] = support_url
        if marketing_url:
            version_attrs["marketingUrl"] = marketing_url
        if locale not in version_locs:
            try:
                asc.post("/v1/appStoreVersionLocalizations", {"data": {
                    "type": "appStoreVersionLocalizations", "attributes": {"locale": locale, **version_attrs},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
                print(f"texts: {locale} ({lang})")
                continue
            except RuntimeError as error:
                # Adding a locale's app info creates its version localization
                # behind the scenes; it then only needs filling in.
                if "already exists" not in str(error):
                    raise
                version_locs = {l["attributes"]["locale"]: l for l in
                                asc.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")}
        asc.patch(f"/v1/appStoreVersionLocalizations/{version_locs[locale]['id']}", {"data": {
            "type": "appStoreVersionLocalizations", "id": version_locs[locale]["id"], "attributes": version_attrs}})
        print(f"texts: {locale} ({lang})")


def step_shots(only):
    version = find_version() or sys.exit("run `version` first")
    locs = {l["attributes"]["locale"]: l for l in
            asc.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")}
    for locale, loc in sorted(locs.items()):
        if only and locale not in only:
            continue
        lang = LOCALE_TO_LANG.get(locale)
        files = sorted(glob.glob(os.path.join(REPO, "docs", "screenshots", "store", lang or "-", "*.png")))
        if len(files) != 9:
            print(f"shots: {locale} skipped — {len(files)} rendered files for {lang}")
            continue
        sets = asc.get_all(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")
        desktop = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
        if desktop is None:
            desktop = asc.post("/v1/appScreenshotSets", {"data": {
                "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                "relationships": {"appStoreVersionLocalization": {"data": {
                    "type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
        for old in asc.get_all(f"/v1/appScreenshotSets/{desktop['id']}/appScreenshots"):
            asc.delete(f"/v1/appScreenshots/{old['id']}")
        ids = [asc.upload_screenshot(desktop["id"], path) for path in files]
        asc.patch(f"/v1/appScreenshotSets/{desktop['id']}/relationships/appScreenshots",
                  {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
        print(f"shots: {locale} ← {lang}, {len(ids)} uploaded")


def step_build():
    version = find_version() or sys.exit("run `version` first")
    builds = asc.get_all("/v1/builds", **{"filter[app]": APP_ID, "filter[version]": BUILD,
                                          "filter[preReleaseVersion.version]": VERSION})
    if not builds:
        sys.exit(f"build {BUILD} of {VERSION} is not in App Store Connect yet")
    build = builds[0]
    state = build["attributes"].get("processingState")
    if state != "VALID":
        sys.exit(f"build {BUILD} is {state}; wait for VALID")
    asc.patch(f"/v1/appStoreVersions/{version['id']}/relationships/build",
              {"data": {"type": "builds", "id": build["id"]}})
    print(f"build {BUILD} attached")

    notes = open(os.path.join(REPO, "docs", "review-notes.txt"), encoding="utf-8").read()
    previous = live_version()
    contact = {}
    if previous:
        try:
            old = asc.get(f"/v1/appStoreVersions/{previous['id']}/appStoreReviewDetail")["data"]
            contact = {k: old["attributes"].get(k) for k in
                       ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")
                       if old["attributes"].get(k)}
        except RuntimeError:
            pass
    attrs = {**contact, "notes": notes, "demoAccountRequired": False}
    try:
        detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")["data"]
        asc.patch(f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": detail["id"], "attributes": attrs}})
    except RuntimeError:
        asc.post("/v1/appStoreReviewDetails", {"data": {
            "type": "appStoreReviewDetails", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    print(f"review notes set ({len(notes)} characters), contact {'copied' if contact else 'MISSING'}")


def step_status():
    version = find_version()
    if not version:
        print("no version yet")
        return
    print(f"version {VERSION}: {version['attributes'].get('appStoreState')}")
    locs = asc.get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")
    print(f"{len(locs)} version localizations")
    counts = {}
    for loc in locs:
        sets = asc.get_all(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")
        n = sum(len(asc.get_all(f"/v1/appScreenshotSets/{s['id']}/appScreenshots")) for s in sets
                if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP")
        counts[loc["attributes"]["locale"]] = n
    print("screenshots per locale:", json.dumps(counts, sort_keys=True))


def step_submit():
    version = find_version() or sys.exit("run `version` first")
    submission = asc.post("/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "MAC_OS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})["data"]
    asc.post("/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    asc.patch(f"/v1/reviewSubmissions/{submission['id']}", {"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    print(f"submitted for review: {submission['id']}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "status"
    {"version": step_version, "texts": step_texts, "build": step_build, "status": step_status,
     "submit": step_submit}.get(command, lambda: step_shots(sys.argv[2:]))() if command != "shots" \
        else step_shots(sys.argv[2:])
