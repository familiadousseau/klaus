"""Gera assets/kws/keywords.txt com a segmentação BPE certa para a palavra "Klaus".
Corre no GitHub Actions (precisa de: pip install sentencepiece)."""
import sentencepiece as spm

sp = spm.SentencePieceProcessor(model_file="tools/kws_bpe.model")
tokens = {l.split()[0] for l in open("assets/kws/tokens.txt", encoding="utf-8")}
# Várias grafias para cobrir a forma como "Klaus" é dito em português.
variants = ["KLAUS", "CLAUS", "KLOUS", "CLOUS", "HEY KLAUS", "OI KLAUS"]
lines = []
for v in variants:
    pieces = sp.encode_as_pieces(v)
    if all(p in tokens for p in pieces):
        lines.append(" ".join(pieces) + " @KLAUS")
open("assets/kws/keywords.txt", "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(open("assets/kws/keywords.txt", encoding="utf-8").read())
