"""Every setting nestjs-api always requires is one Katap's template provides.

Usage: check_nestjs_settings.py <nestjs-api env.validation.ts> <templates/nestjs-api.env.spec> [<nestjs-api prisma/seed.ts>]

A key is "always required" when its Joi schema calls `.required()` with no
`when`/`is:` condition; conditional ones (a provider's API key) are the
operator's to fill. With the seeder, so are the SEED_<ACCOUNT>_EMAIL and
_PASSWORD of every account it seeds (`readSeedUser('<ACCOUNT>'`), which
`katap run … prisma:seed` needs. Exits 1, naming them, when any is missing from
the spec.
"""
import re
import sys

validation, spec = (open(path).read() for path in sys.argv[1:3])
provided = set(re.findall(r'^([A-Z][A-Z0-9_]*)=', spec, re.M))
missing = []
if len(sys.argv) > 3:
    accounts = re.findall(r"readSeedUser\(\s*'([A-Z]+)'", open(sys.argv[3]).read())
    if not accounts:
        print('no readSeedUser(...) call in the seeder: this check no longer reads it')
        sys.exit(1)
    missing += [f'SEED_{a}_{k}' for a in accounts for k in ('EMAIL', 'PASSWORD')
                if f'SEED_{a}_{k}' not in provided]
for block in re.split(r'\n  (?=[A-Z][A-Z0-9_]+: )', validation):
    key = re.match(r'([A-Z][A-Z0-9_]+): ', block)
    body = block[:1800]
    if key and '.required()' in body and 'when' not in body and 'is:' not in body \
            and key.group(1) not in provided:
        missing.append(key.group(1))
if missing:
    print('missing from the template: ' + ' '.join(missing))
    sys.exit(1)
