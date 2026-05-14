# snmp_exporter Generator

Offline tool for generating `snmp.yml` from MIB definitions. The generator runs via Docker — no local Go toolchain required.

## Prerequisites

- Docker
- Vendor MIB files placed in `mibs/` (see `mibs/README.md`)

## Usage

1. Place any vendor-specific MIB files in `mibs/`.
2. Edit `generator.yml` to define modules and OID walks.
3. Run the generator:

```bash
./generate.sh
```

4. Review the generated `snmp.yml` in this directory.
5. Deploy it:

```bash
cp snmp.yml ../snmp.yml
docker compose restart snmp-exporter
```

## Adding a new SNMP module

1. Identify the MIBs and OIDs you need (vendor docs, `snmpwalk`, MIB browser).
2. Place any vendor MIBs in `mibs/`.
3. Add a new module block to `generator.yml` with the OIDs to walk.
4. Run `./generate.sh` and review the output.
5. Deploy and add a corresponding Prometheus scrape job (see `prometheus/prometheus.yml`).

## Manual module authoring

If vendor MIBs are unavailable, you can write modules directly in `../snmp.yml` using numeric OIDs. See the `paloalto_gp` module for an example of this approach.

## Standard MIBs

The generator Docker image includes IETF standard MIBs (IF-MIB, SNMPv2-MIB, etc.). Only vendor-specific MIBs need to be placed in `mibs/`.
