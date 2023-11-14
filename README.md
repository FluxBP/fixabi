# fixabi
Adds secondary indexes to ABI files

## Requirements

* `perl`
* `jq` (not mandatory; for indented output only)

## Usage

`fixabi.pl` processes only one input C++ file at a time. If the source for the ABI is spread across multiple files, you have to call `fixabi.pl` for each one, and pass the output file as the input file of the next call.

```
$ chmod +x fixabi.pl
$ ./fixabi.pl
Usage: ./fixabi.pl <input ABI file> <input C++ file> [output ABI file]
```

Example (if you put it in a directory in your `PATH`):

```
~/doh/doh-hegemon-contract$ fixabi.pl build/hegemon/hegemon.abi include/hegemon.hpp fixed.json
~/doh/doh-hegemon-contract$ diff fixed.json build/hegemon/hegemon.abi
  (...)
~/doh/doh-hegemon-contract$ cp fixed.json build/hegemon/hegemon.abi
```

## Spec

```
Example entry for a table before post processing :

        {
            "name": "players",
            "type": "player",
            "index_type": "i64",
            "key_names": [],
            "key_types": []
        }

This is the table index definition.

      typedef eosio::multi_index< "players"_n, player,
           indexed_by<"unique"_n, const_mem_fun<player, uint64_t, &player::by_unique>>,
           indexed_by<"faction"_n, const_mem_fun<player, uint64_t, &player::by_faction>>,
           indexed_by<"location"_n, const_mem_fun<player, uint64_t, &player::by_location>>,
           indexed_by<"locafaction"_n, const_mem_fun<player, uint128_t, &player::by_location_faction>>> players_table;

When post-processing is complete, the resulting table entry in the ABI should be this:

        {
            "name": "players",
            "type": "player",
            "index_type": "i64",
            "key_names": ["unique", "faction", "location", "locafaction"],
            "key_types": [i64, i64, i64, i128]
        }

Supported key_types are : i64, i128, i256, float64, float128, ripemd160, sha256
```
