# Treino da palavra "Klaus"

Caderno do Google Colab que treina um modelo **microWakeWord** para a palavra **"Klaus"**,
com vozes sintéticas em vários sotaques e línguas (pt-BR, pt-PT, it, de, es, fr, en).

O mesmo ficheiro `klaus.tflite` serve para o app Android e para a placa ESP32-S3.

[![Abrir no Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/familiadousseau/klaus/blob/main/tools/treino_klaus/treino_klaus.ipynb)

## Passos
1. Abra o link acima (com a sua conta Google).
2. **Ambiente de execução → Alterar tipo → GPU (T4)**.
3. Corra as células pela ordem. Depois da célula 1, **reinicie a sessão**.
4. No fim, descarregue `klaus_wakeword.zip` e envie-o.

O treino demora várias horas no Colab grátis. Se a sessão cair, volte a correr a célula 12 (retoma).
