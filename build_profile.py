#!/usr/bin/env python3
"""Builds the two plists install.sh pushes to the phone. Stdlib only.

  build_profile.py profile  OUT            -> dumb.mobileconfig (restrictions + layout + web clip)
  build_profile.py certs    OUT            -> certs.mobileconfig (root certs only, separate so it survives --undo)
  build_profile.py ca       OUT PEM        -> trust a private CA (the WhatsApp bridge's)
  build_profile.py cloud    OUT KEYBAG     -> cloud configuration that marks the phone as supervised
"""
import plistlib
import ssl
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).parent
ORG = "dumb iPhone"
ID = "local.dumbiphone"

# The whole phone, modelled on the Light Phone tool set. Edit and run install.sh again.
DOCK = ["com.apple.mobilephone", "com.apple.MobileSMS", "com.apple.camera"]
PAGE_1 = [
    "com.apple.Maps",            # Directions
    "com.apple.podcasts",        # Podcasts
    "com.apple.Music",           # Music
    "com.apple.mobileslideshow", # Photos
    "com.apple.mobiletimer",     # Alarm + Timer
    "com.apple.mobilecal",       # Calendar
    "com.apple.mobilenotes",     # Notes
    "com.apple.VoiceMemos",      # Voice memo
    "com.apple.calculator",      # Calculator
    "com.apple.mobilesafari",    # light web (see WEB_CLIP)
    "net.whatsapp.WhatsApp",     # only shows if installed (needs iOS 15+, so not on a 4S)
    "com.google.Maps",           # same: only if already installed
]
PAGE_2 = ["com.apple.Preferences"]  # hotspot lives in Settings

WEB_CLIP = {"label": "web", "url": "http://frogfind.com"}  # plain-HTTP text proxy: works on iOS 9 Safari

# Stock iOS 9 apps to hide. Phone, Messages, Settings can't be hidden anyway.
HIDE = [
    "com.apple.AppStore", "com.apple.MobileStore", "com.apple.reminders", "com.apple.weather",
    "com.apple.stocks", "com.apple.mobilemail", "com.apple.videos", "com.apple.gamecenter",
    "com.apple.Passbook", "com.apple.Health", "com.apple.iBooks", "com.apple.news", "com.apple.tips",
    "com.apple.facetime", "com.apple.MobileAddressBook", "com.apple.compass", "com.apple.mobileme.fmip1",
    "com.apple.mobileme.fmf1", "com.apple.Bridge", "com.apple.iCloudDriveApp",
]


def payload(ptype, name, **body):
    return {
        "PayloadType": ptype,
        "PayloadVersion": 1,
        "PayloadIdentifier": f"{ID}.{name}",
        "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{ID}.{name}")),
        "PayloadDisplayName": name,
        **body,
    }


def apps(ids):
    return [{"Type": "Application", "BundleID": b} for b in ids]


def root_certs():
    return [
        payload("com.apple.security.root", f"root-{pem.stem}",
                PayloadContent=ssl.PEM_cert_to_DER_cert(pem.read_text()))
        for pem in sorted((HERE / "certs").glob("*.pem"))
    ]


def certs_profile():
    """Just the root certs: lets iOS 9 (Safari, Cydia) open Let's Encrypt / Google sites."""
    return payload("Configuration", "certs", PayloadDisplayName="Modern root certificates",
                   PayloadOrganization=ORG, PayloadRemovalDisallowed=False, PayloadContent=root_certs())


def ca_profile(pem):
    """A private CA (the WhatsApp bridge's), so iOS trusts the bridge's HTTPS page."""
    return payload("Configuration", "wabridge-ca", PayloadDisplayName="WhatsApp bridge certificate",
                   PayloadOrganization=ORG, PayloadRemovalDisallowed=False,
                   PayloadContent=[payload("com.apple.security.root", "wabridge-ca-root",
                                           PayloadContent=ssl.PEM_cert_to_DER_cert(Path(pem).read_text()))])


def profile():
    return payload(
        "Configuration", "profile",
        PayloadDisplayName="dumb iPhone",
        PayloadDescription="Hides everything except calls, messages, maps, podcasts and light web.",
        PayloadOrganization=ORG,
        PayloadRemovalDisallowed=False,
        PayloadContent=[
            payload("com.apple.applicationaccess", "restrictions",
                    blacklistedAppBundleIDs=HIDE,
                    allowAppInstallation=False,
                    allowUIAppInstallation=False,
                    allowGameCenter=False,
                    allowInAppPurchases=False,
                    allowiTunes=False,
                    allowBookstore=False,
                    allowNews=False,
                    allowExplicitContent=False),
            payload("com.apple.homescreenlayout", "layout",
                    Dock=apps(DOCK),
                    Pages=[apps(PAGE_1), apps(PAGE_2)]),
            payload("com.apple.webClip.managed", "webclip",
                    Label=WEB_CLIP["label"], URL=WEB_CLIP["url"],
                    Icon=(HERE / "assets/web.png").read_bytes(),
                    IsRemovable=False, FullScreen=False, Precomposed=True),
        ],
    )


def cloud(keybag):
    pem = keybag.read_text()
    cert = pem[pem.index("-----BEGIN CERTIFICATE-----"):pem.index("-----END CERTIFICATE-----") + 25]
    return {
        "AllowPairing": True,
        "CloudConfigurationUIComplete": True,
        "ConfigurationSource": 2,
        "ConfigurationWasApplied": True,
        "IsMDMUnremovable": False,
        "IsMandatory": False,
        "IsMultiUser": False,
        "IsSupervised": True,
        "OrganizationMagic": str(uuid.uuid4()),
        "OrganizationName": ORG,
        "PostSetupProfileWasInstalled": True,
        # Wi-Fi, Apple ID (iMessage) and Location (Maps) stay: you set those up on the phone.
        "SkipSetup": ["Siri", "Diagnostics", "Restore", "Payment", "TouchID", "Zoom", "DisplayTone", "Android"],
        "SupervisorHostCertificates": [ssl.PEM_cert_to_DER_cert(cert)],
    }


if __name__ == "__main__":
    kind, out = sys.argv[1], Path(sys.argv[2])
    if kind == "cloud":
        data = cloud(Path(sys.argv[3]))
    elif kind == "ca":
        data = ca_profile(sys.argv[3])
    else:
        data = {"profile": profile, "certs": certs_profile}[kind]()
    out.write_bytes(plistlib.dumps(data))
    print(f"wrote {out}")
