"""Every setting nestjs-api always requires at boot is one Katap's template provides.

Usage: check_nestjs_settings.py <nestjs-api env.validation.ts> <templates/nestjs-api.env.spec>

A key is "always required" when its Joi schema calls `.required()` with no
`when`/`is:` condition; conditional ones (a provider's API key) are the
operator's to fill. Exits 1, naming them, when any is missing from the spec.
"""
import re
import sys

validation, spec = (open(path).read() for path in sys.argv[1:3])
provided = set(re.findall(r'^([A-Z][A-Z0-9_]*)=', spec, re.M))
missing = []
for block in re.split(r'\n  (?=[A-Z][A-Z0-9_]+: )', validation):
    key = re.match(r'([A-Z][A-Z0-9_]+): ', block)
    body = block[:1800]
    if key and '.required()' in body and 'when' not in body and 'is:' not in body \
            and key.group(1) not in provided:
        missing.append(key.group(1))
if missing:
    print('missing from the template: ' + ' '.join(missing))
    sys.exit(1)
