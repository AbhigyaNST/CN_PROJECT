# Evidence Folder — structure & naming

> **NOTE:** the files currently in these folders are SAMPLES generated
> during the project's verification run in the single-machine simulation
> (2026-09-20, see `docs/SIMULATION_RESULTS.md`). They show the exact
> expected format/content. **Replace and augment them with captures from
> YOUR 4-Mac network** before submission.

The brief: *"The evaluator should be able to find any piece of evidence
within 30 seconds."* Hence deterministic folders + numbered files.

| Folder | Put here | Filled by |
|---|---|---|
| `dns/` | dig/nslookup outputs, dnsmasq query-log excerpts | `collect-evidence.sh` + screenshots |
| `tcp/` | port probes, `.pcap` captures (Wireshark-openable), handshake screenshots | `collect-evidence.sh --capture` + manual |
| `tls/` | `openssl s_client` records, `curl -v` transcripts, Wireshark TLS screenshots | same |
| `http/` | response headers, redirect proof, nginx access/error log excerpts | same |
| `load-balancing/` | X-Backend alternation runs (12 requests) | same |
| `caching/` | Cache-Control/ETag headers + the 304 exchange | same |
| `failures/` | transcript + screenshot per scenario 1–5 | `failures.sh a \| tee failures/all.txt` |
| `phase2/` | transcript per extension a–e + diagnose baseline f | `demo-phase2.sh x \| tee phase2/x.txt` |

Rules we follow:
1. Text files are self-describing: first lines = the exact command, date,
   machine (collect-evidence.sh adds them automatically).
2. Screenshots named `NN-SCREENSHOT-<what>.png` inside the same folder.
3. `.pcap` files never edited; Wireshark text exports live beside them.
4. `INDEX.md` (auto-generated) is the map — open it first during evaluation.
