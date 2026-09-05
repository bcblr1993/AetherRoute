#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RESOURCE_DIRECTORY=${1:-"$ROOT/Config/RoutingResources"}

python3 - "$RESOURCE_DIRECTORY" <<'PY'
import datetime
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

root = Path(sys.argv[1])

def require(condition, message):
    if not condition:
        raise ValueError(message)

def read_regular(name, limit):
    require(isinstance(name, str) and Path(name).name == name and name not in ('.', '..'),
            'Unsafe resource or notice path')
    path = root / name
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode), f'{name} must be a regular file, not a symlink')
    require(0 < info.st_size <= limit, f'{name} has an invalid file size')
    data = path.read_bytes()
    require(len(data) == info.st_size, f'{name} changed during verification')
    return data

def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        require(offset < len(data), 'Truncated protobuf varint')
        byte = data[offset]
        offset += 1
        if shift == 63:
            require(byte <= 1, 'Oversized protobuf varint')
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, offset
    raise ValueError('Oversized protobuf varint')

def fields(data):
    offset = 0
    while offset < len(data):
        key, offset = varint(data, offset)
        number, wire = key >> 3, key & 7
        require(0 < number < 2**29, 'Invalid protobuf field number')
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, offset = varint(data, offset)
            else:
                size = 8 if wire == 1 else 4
            require(size <= len(data) - offset, 'Truncated protobuf field')
            value = data[offset:offset + size]
            offset += size
        else:
            raise ValueError('Unsupported protobuf wire type')
        yield number, wire, value

def validate_geosite(data):
    sites = domains = 0
    codes = set()
    for number, wire, entry in fields(memoryview(data)):
        require(number == 1 and wire == 2, 'Not a GeoSiteList protobuf')
        code = None
        for field, kind, value in fields(entry):
            if field == 1:
                require(kind == 2 and code is None, 'Invalid GeoSite category')
                code = bytes(value).decode('utf-8')
                require(bool(code) and len(code) <= 256, 'Empty or oversized GeoSite category')
            elif field == 2:
                require(kind == 2, 'Invalid GeoSite domain message')
                domain_value = None
                for domain_field, domain_wire, domain_data in fields(value):
                    if domain_field == 1:
                        require(domain_wire == 0 and domain_data in (0, 1, 2, 3),
                                'Unsupported GeoSite domain type')
                    elif domain_field == 2:
                        require(domain_wire == 2 and domain_value is None,
                                'Invalid GeoSite domain value')
                        domain_value = bytes(domain_data).decode('utf-8')
                    elif domain_field == 3:
                        require(domain_wire == 2, 'Invalid GeoSite attribute')
                        list(fields(domain_data))
                require(bool(domain_value), 'GeoSite domain has no value')
                domains += 1
        require(code is not None, 'GeoSite entry has no category')
        codes.add(code.upper())
        sites += 1
    require(sites > 0 and domains > 0 and 'CN' in codes, 'GeoSite data lacks routing categories')
    return f'GeoSiteList categories={sites} domains={domains}'

try:
    require(root.is_dir() and not root.is_symlink(), 'Unsafe resource directory')
    manifest = json.loads(read_regular('manifest.json', 16 * 1024))
    require(manifest.get('schema') == 1, 'Unsupported resource manifest schema')
    packaged_at = datetime.datetime.fromisoformat(manifest['packagedAt'].replace('Z', '+00:00'))
    require(packaged_at.utcoffset() is not None, 'packagedAt requires a timezone')
    require(packaged_at <= datetime.datetime.now(datetime.timezone.utc), 'packagedAt is in the future')
    entries = manifest['resources']
    require(len(entries) == 2, 'The bundled pack must include both resources')
    require({e['kind'] for e in entries} == {'countryMMDB', 'geoSite'}, 'Duplicate or unknown resource kind')
    notices = json.loads(read_regular('notices.json', 256 * 1024))
    require(len(notices['components']) == 2 and len(notices['licenses']) == 2,
            'Resource notices must cover the two data components')
    components = {c['name'] + '@' + c['version']: c for c in notices['components']}
    require(len(components) == 2, 'Duplicate notice component')
    for entry in entries:
        kind = entry['kind']
        expected_name, expected_license = {
            'countryMMDB': ('Country.mmdb', 'CC-BY-4.0'),
            'geoSite': ('GeoSite.dat', 'MIT'),
        }[kind]
        require(entry['fileName'] == expected_name, 'Resource filename does not match its kind')
        data = read_regular(expected_name, 64 * 1024 * 1024)
        require(type(entry['byteCount']) is int and len(data) == entry['byteCount'],
                f'{expected_name} byte count mismatch')
        require(re.fullmatch('[0-9a-f]{64}', entry['sha256']) is not None,
                f'{expected_name} has an invalid SHA-256')
        require(hashlib.sha256(data).hexdigest() == entry['sha256'],
                f'{expected_name} SHA-256 mismatch')
        source = urlsplit(entry['sourceURL'])
        require(source.scheme == 'https' and source.hostname and not source.username and not source.password,
                'Resource source must be a public HTTPS URL')
        require(entry['sourceLicense'] == expected_license and bool(entry['attribution']),
                'Missing or unexpected resource license/attribution')
        license_text = read_regular(entry['licenseFile'], 128 * 1024).decode('utf-8')
        notice_text = read_regular(entry['noticeFile'], 128 * 1024).decode('utf-8')
        require(entry['attribution'] in notice_text, 'Attribution is absent from resource notice')
        component = components.get(entry['component'])
        require(component is not None and component['license'] == expected_license,
                'Resource is missing from notices.json')
        license_entries = [item for item in notices['licenses']
                           if entry['component'] in item['components'] and item['id'] == expected_license]
        require(len(license_entries) == 1 and license_text in license_entries[0]['text'],
                'Complete license text is missing from notices.json')
        if kind == 'countryMMDB':
            require(source.hostname == 'download.db-ip.com', 'Bundled country data must come from DB-IP')
            tail = data[-128 * 1024:]
            marker = b'\xab\xcd\xefMaxMind.com'
            position = tail.rfind(marker)
            require(position >= 0 and b'DBIP-Country-Lite' in tail[position:],
                    'Country.mmdb is not a DB-IP Lite Country MMDB')
            require('Section 8' in license_text, 'CC BY 4.0 legal code is incomplete')
            detail = 'MMDB DBIP-Country-Lite'
        else:
            require(source.hostname == 'github.com' and source.path.startswith('/v2fly/domain-list-community/'),
                    'Bundled GeoSite data must come from V2Fly')
            require('Copyright (c) 2018-2019 V2Ray' in license_text and 'THE SOFTWARE IS PROVIDED' in license_text,
                    'V2Fly MIT license is incomplete')
            detail = validate_geosite(data)
        print(f'{expected_name}: bytes={len(data)} sha256={entry["sha256"]} type={detail} license={expected_license}')
    print('Bundled routing resources verified: both data files, types, hashes, sizes, and complete notices.')
except (KeyError, TypeError, ValueError, OSError, UnicodeError) as error:
    print(f'Bundled routing resources invalid: {error}', file=sys.stderr)
    sys.exit(1)
PY
