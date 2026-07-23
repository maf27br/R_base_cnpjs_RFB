# BASE_CNPJ_RFB

Gera um banco **SQLite portátil** (`data/cnpj.db`) com a base de **CNPJs** dos
[Dados Abertos da Receita Federal](https://arquivos.receitafederal.gov.br/dados/cnpj/).
Baixa os arquivos oficiais, descompacta e monta um único arquivo `.db` com índices
prontos para consulta — fácil de copiar para outro computador.

- **Competência atual:** `2026-07` (extração interna `D60711` = 11/07/2026)
- **Tamanho do `.db`:** ~40 GB
- **Empresas (matrizes):** 69.062.850 · **Estabelecimentos:** 72.318.968 · **Sócios:** 27.992.378 · **Simples/MEI:** 49.445.426

---

## Requisitos

Linux com **R 4.x** e alguns pacotes (binários via apt, sem compilação):

```bash
sudo apt-get install -y r-base-core \
  r-cran-data.table r-cran-rsqlite r-cran-dbi r-cran-glue r-cran-fs r-cran-stringi
```

> `Rtools` é do Windows e **não** se aplica aqui. Ferramentas de sistema usadas:
> `curl`, `unzip`, `sqlite3`.

---

## Como atualizar a base (recriar o `.db`)

1. **Descobrir a competência mais recente.** No portal da RFB, a pasta atual fica em
   `.../s/<TOKEN>?dir=/Dados/Cadastros/CNPJ/<AAAA-MM>`. Anote o `<TOKEN>` da URL e o mês.

2. **Baixar os 37 zips** (~7 GB) para `raw-data/`. Duas opções:
   - **Manual:** entrar no site, marcar a pasta e baixar (mais confiável; o servidor
     costuma dar `HTTP 500` sob carga).
   - **Script** (resumível/idempotente; ajuste `TOKEN`/`REMOTE_DIR` no topo dele):
     ```bash
     bash src/download_rfb.sh
     ```
   Arquivos esperados: `Empresas0-9`, `Estabelecimentos0-9`, `Socios0-9`, `Simples`,
   `Cnaes`, `Motivos`, `Municipios`, `Naturezas`, `Paises`, `Qualificacoes`.

3. **Construir o banco** (descompacta em `data/` e monta o `.db`). Ajuste
   `dataReferencia` no topo do script para a competência baixada:
   ```bash
   Rscript src/v2_import_convert.R
   ```
   > O script aborta se `data/cnpj.db` já existir — apague o antigo antes de recriar.

4. **(Opcional) Limpar intermediários.** Após o build, os CSVs extraídos em `data/`
   (~27 GB) não são mais necessários (regeneráveis dos zips):
   ```bash
   find data/ -maxdepth 1 -type f ! -name 'cnpj.db' ! -name '*.log' -delete
   ```

O resultado portátil é apenas o arquivo **`data/cnpj.db`**.

---

## Esquema do banco

**Tabelas grandes**

| Tabela | Descrição | Colunas-chave |
|---|---|---|
| `empresas` | Dados da matriz (razão social, natureza, porte, `capital_social` REAL) | `cnpj_basico` (8 díg.) |
| `estabelecimento` | Cada estabelecimento (matriz/filial); endereço, CNAE, situação | `cnpj_basico`, `cnpj` (14 díg. = básico+ordem+dv), `cnae_fiscal`, `uf`, `municipio` |
| `socios` | Sócios das **matrizes** (join com estabelecimento onde `matriz_filial='1'`) | `cnpj`, `cnpj_basico`, `cnpj_cpf_socio`, `nome_socio` |
| `simples` | Opção pelo Simples Nacional / MEI | `cnpj_basico` |

**Tabelas de código** (`codigo`, `descricao`): `cnae`, `motivo`, `municipio`,
`natureza_juridica`, `pais`, `qualificacao_socio`.

**Metadados:** `_referencia` (`CNPJ`=competência, `cnpj_qtde`, `gerado_em`).

**Índices** criados (20), incluindo: `cnpj_basico`/`cnpj` (empresas, estabelecimento,
socios), **`cnae_fiscal`**, `uf`, `municipio`, `nome_fantasia`, `razao_social`,
`nome_socio`, `cnpj_cpf_socio`, e os `codigo` das tabelas de apoio.

---

## Exemplos de consulta

```sql
-- Empresa completa por CNPJ (14 dígitos)
SELECT em.razao_social, es.nome_fantasia, es.uf, es.cnae_fiscal
FROM estabelecimento es
JOIN empresas em ON em.cnpj_basico = es.cnpj_basico
WHERE es.cnpj = '61686626000198';

-- Estabelecimentos por CNAE (usa idx_estabelecimento_cnae_fiscal)
SELECT es.cnpj, es.nome_fantasia, es.uf, mu.descricao AS municipio
FROM estabelecimento es
LEFT JOIN municipio mu ON mu.codigo = es.municipio
WHERE es.cnae_fiscal = '6201501'      -- Desenvolvimento de software sob encomenda
  AND es.matriz_filial = '1';

-- Sócios de uma empresa
SELECT nome_socio, qualificacao_socio, data_entrada_sociedade
FROM socios WHERE cnpj_basico = '61686626';
```

Rodar direto no terminal:

```bash
sqlite3 data/cnpj.db "SELECT descricao FROM cnae WHERE codigo='6201501';"
```

---

## Estrutura do projeto

```
src/download_rfb.sh        # baixa os zips da RFB (WebDAV, resumível)
src/v2_import_convert.R     # descompacta + monta o cnpj.db com índices  (script atual)
src/V1_import_convert.R     # versão original (histórica; ver notas abaixo)
raw-data/                   # zips baixados (~7 GB)
data/cnpj.db               # banco final (portátil)
```

### Notas sobre o `v2` (vs. `V1` original)

O `V1_import_convert.R` **não roda** como está. O `v2` corrige:

1. Chave `}` órfã (erro de sintaxe).
2. As tabelas grandes nunca eram carregadas (a função `carregaTipo()` era definida mas
   **nunca chamada**) — o banco sairia vazio.
3. Download por URL antiga/morta + prompt interativo → agora o download é separado
   (`download_rfb.sh`) e o build é não-interativo.
4. Adicionado **índice de CNAE** (`idx_estabelecimento_cnae_fiscal`) e de `uf`/`municipio`.
