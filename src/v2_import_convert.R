#!/usr/bin/env Rscript
# -*- coding: utf-8 -*-
# BASE_CNPJ_RFB - v2 (2026)
# Reconstrói o SQLite portátil data/cnpj.db a partir dos zips da RFB.
# Diferenças vs v1:
#   - Download é feito FORA deste script (src/download_rfb.sh); aqui NÃO baixamos.
#   - Corrigido: chamadas carregaTipo() das tabelas grandes estavam ausentes.
#   - Corrigido: chave "}" órfã / seção interativa removida.
#   - Índice de CNAE (cnae_fiscal) adicionado.
# Requisitos: data.table, DBI, RSQLite, glue, fs, stringi
# Uso: Rscript src/v2_import_convert.R   (rodar na raiz do projeto)

suppressPackageStartupMessages({
  library(data.table)
  library(DBI)
  library(RSQLite)
  library(glue)
  library(fs)
  library(stringi)
})

# --------- CONFIGURAÇÕES ----------
pasta_compactados <- "./raw-data/"   # onde estão os .zip baixados
pasta_saida       <- "./data/"       # onde os CSV extraídos e o DB serão criados
dataReferencia    <- "2026-07"       # competência
# ----------------------------------

dir_create_if_missing <- function(path) if (!dir_exists(path)) dir_create(path, recurse = TRUE)
dir_create_if_missing(pasta_compactados)
dir_create_if_missing(pasta_saida)

zip_files <- dir_ls(pasta_compactados, glob = "*.zip")
if (length(zip_files) == 0) stop(glue("Nenhum .zip em {pasta_compactados}. Rode src/download_rfb.sh antes."))
cat(length(zip_files), "arquivos zip encontrados em", pasta_compactados, "\n")

# 3) descompacta todos os zips para pasta_saida
for (zf in zip_files) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "- descompactando", zf, "\n")
  unzip(zipfile = zf, exdir = pasta_saida)
}

# 4) cria o DB SQLite
db_path <- path(pasta_saida, "cnpj.db")
if (file_exists(db_path)) stop(glue("{db_path} já existe. Apague-o primeiro e rode novamente."))

con <- dbConnect(RSQLite::SQLite(), dbname = db_path)
on.exit(try(dbDisconnect(con), silent = TRUE))
# PRAGMAs de performance para a carga em massa
dbExecute(con, "PRAGMA journal_mode = OFF;")
dbExecute(con, "PRAGMA synchronous = OFF;")
dbExecute(con, "PRAGMA temp_store = MEMORY;")

cat("Início:", format(Sys.time()), "\n")

# --- tabelas de código (pequenas): codigo;descricao ---
carregaTabelaCodigo <- function(extensaoArquivo, nomeTabela) {
  files <- dir_ls(pasta_saida, regexp = paste0(extensaoArquivo, "$"), ignore.case = TRUE)
  if (length(files) == 0) { cat("Aviso: sem arquivo", extensaoArquivo, "\n"); return(invisible(NULL)) }
  arquivo <- files[1]
  cat("carregando tabela", arquivo, "\n")
  dt <- fread(arquivo, sep = ";", header = FALSE, encoding = "Latin-1",
              col.names = c("codigo","descricao"), colClasses = "character")
  dbWriteTable(con, nomeTabela, dt, overwrite = TRUE, row.names = FALSE)
  dbExecute(con, glue("CREATE INDEX idx_{nomeTabela} ON {nomeTabela}(codigo);"))
}

carregaTabelaCodigo("\\.CNAECSV",  "cnae")
carregaTabelaCodigo("\\.MOTICSV",  "motivo")
carregaTabelaCodigo("\\.MUNICCSV", "municipio")
carregaTabelaCodigo("\\.NATJUCSV", "natureza_juridica")
carregaTabelaCodigo("\\.PAISCSV",  "pais")
carregaTabelaCodigo("\\.QUALSCSV", "qualificacao_socio")

# 5) tabelas grandes: cria esquema vazio (TEXT) e insere por append
sqlCriaTabela <- function(nomeTabela, colunas) {
  cols_def <- paste0(colunas, " TEXT", collapse = ",\n  ")
  dbExecute(con, glue("CREATE TABLE {nomeTabela} (\n  {cols_def}\n);"))
}

colunas_empresas <- c('cnpj_basico','razao_social','natureza_juridica',
                      'qualificacao_responsavel','capital_social_str',
                      'porte_empresa','ente_federativo_responsavel')

colunas_estabelecimento <- c('cnpj_basico','cnpj_ordem','cnpj_dv','matriz_filial',
                             'nome_fantasia','situacao_cadastral','data_situacao_cadastral',
                             'motivo_situacao_cadastral','nome_cidade_exterior','pais',
                             'data_inicio_atividades','cnae_fiscal','cnae_fiscal_secundaria',
                             'tipo_logradouro','logradouro','numero','complemento','bairro',
                             'cep','uf','municipio','ddd1','telefone1','ddd2','telefone2',
                             'ddd_fax','fax','correio_eletronico','situacao_especial',
                             'data_situacao_especial')

colunas_socios <- c('cnpj_basico','identificador_de_socio','nome_socio','cnpj_cpf_socio',
                    'qualificacao_socio','data_entrada_sociedade','pais','representante_legal',
                    'nome_representante','qualificacao_representante_legal','faixa_etaria')

colunas_simples <- c('cnpj_basico','opcao_simples','data_opcao_simples','data_exclusao_simples',
                     'opcao_mei','data_opcao_mei','data_exclusao_mei')

sqlCriaTabela("empresas",        colunas_empresas)
sqlCriaTabela("estabelecimento", colunas_estabelecimento)
sqlCriaTabela("socios_original", colunas_socios)
sqlCriaTabela("simples",         colunas_simples)

# 6) carrega cada tipo grande (append por arquivo, liberando memória)
carregaTipo <- function(nome_tabela, tipo_pattern, colunas) {
  arquivos <- dir_ls(pasta_saida, regexp = tipo_pattern, ignore.case = TRUE)
  if (length(arquivos) == 0) { cat("Nenhum arquivo p/ padrão", tipo_pattern, "\n"); return(invisible(NULL)) }
  for (arq in arquivos) {
    cat("carregando:", arq, "-", format(Sys.time()), "\n")
    dt <- fread(arq, sep = ";", header = FALSE, encoding = "Latin-1",
                col.names = colunas, colClasses = "character", na.strings = "")
    missing_cols <- setdiff(colunas, names(dt))
    for (mc in missing_cols) dt[[mc]] <- NA_character_
    dbWriteTable(con, nome_tabela, dt, append = TRUE, row.names = FALSE)
    rm(dt); gc()
  }
}

# Padrões das extensões internas dos CSV da RFB
carregaTipo("empresas",        "\\.EMPRECSV$", colunas_empresas)
carregaTipo("estabelecimento", "\\.ESTABELE$", colunas_estabelecimento)
carregaTipo("socios_original", "\\.SOCIOCSV$", colunas_socios)
carregaTipo("simples",         "SIMPLES\\.CSV", colunas_simples)

# 7) Ajustes finais: capital_social real, coluna cnpj, índices
cat("Ajustes SQL finais...\n")

dbExecute(con, "ALTER TABLE empresas ADD COLUMN capital_social real;")
dbExecute(con, "UPDATE empresas SET capital_social = CAST(REPLACE(capital_social_str, ',', '.') AS REAL);")

cat("Removendo coluna capital_social_str...\n")
cols_empresas_keep <- setdiff(dbGetQuery(con, "PRAGMA table_info(empresas);")$name, "capital_social_str")
cols_select <- paste(cols_empresas_keep, collapse = ", ")
dbExecute(con, glue("CREATE TABLE empresas_new AS SELECT {cols_select} FROM empresas;"))
dbExecute(con, "DROP TABLE empresas;")
dbExecute(con, "ALTER TABLE empresas_new RENAME TO empresas;")

dbExecute(con, "ALTER TABLE estabelecimento ADD COLUMN cnpj TEXT;")
dbExecute(con, "UPDATE estabelecimento SET cnpj = cnpj_basico || cnpj_ordem || cnpj_dv;")

cria_idx_safe <- function(sql) tryCatch(dbExecute(con, sql),
  error = function(e) message("Aviso índice: ", conditionMessage(e)))

cria_idx_safe("CREATE INDEX idx_empresas_cnpj_basico ON empresas (cnpj_basico);")
cria_idx_safe("CREATE INDEX idx_empresas_razao_social ON empresas (razao_social);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_cnpj_basico ON estabelecimento (cnpj_basico);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_cnpj ON estabelecimento (cnpj);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_nomefantasia ON estabelecimento (nome_fantasia);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_cnae_fiscal ON estabelecimento (cnae_fiscal);")  # <- CNAE
cria_idx_safe("CREATE INDEX idx_estabelecimento_uf ON estabelecimento (uf);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_municipio ON estabelecimento (municipio);")
cria_idx_safe("CREATE INDEX idx_socios_original_cnpj_basico ON socios_original(cnpj_basico);")

# 8) tabela socios (apenas matrizes) via join
cat("Criando tabela socios (matrizes)...\n")
dbExecute(con, "CREATE TABLE socios AS
  SELECT te.cnpj as cnpj, ts.*
  FROM socios_original ts
  LEFT JOIN estabelecimento te ON te.cnpj_basico = ts.cnpj_basico
  WHERE te.matriz_filial = '1';")
dbExecute(con, "DROP TABLE IF EXISTS socios_original;")

cria_idx_safe("CREATE INDEX idx_socios_cnpj ON socios(cnpj);")
cria_idx_safe("CREATE INDEX idx_socios_cnpj_cpf_socio ON socios(cnpj_cpf_socio);")
cria_idx_safe("CREATE INDEX idx_socios_nome_socio ON socios(nome_socio);")
cria_idx_safe("CREATE INDEX idx_socios_representante ON socios(representante_legal);")
cria_idx_safe("CREATE INDEX idx_socios_representante_nome ON socios(nome_representante);")
cria_idx_safe("CREATE INDEX idx_simples_cnpj_basico ON simples(cnpj_basico);")

# 9) metadata
dbExecute(con, "CREATE TABLE IF NOT EXISTS _referencia (referencia TEXT, valor TEXT);")
qtde_cnpjs <- dbGetQuery(con, "SELECT COUNT(*) AS c FROM estabelecimento;")$c
dbExecute(con, "INSERT INTO _referencia (referencia, valor) VALUES (:r, :v);", params = list(r = "CNPJ", v = dataReferencia))
dbExecute(con, "INSERT INTO _referencia (referencia, valor) VALUES (:r, :v);", params = list(r = "cnpj_qtde", v = as.character(qtde_cnpjs)))
dbExecute(con, "INSERT INTO _referencia (referencia, valor) VALUES (:r, :v);", params = list(r = "gerado_em", v = format(Sys.time(), "%Y-%m-%d %H:%M:%S")))

# 10) contagens finais + otimização
qt_empresas <- dbGetQuery(con, "SELECT COUNT(*) c FROM empresas;")$c
qt_estab    <- dbGetQuery(con, "SELECT COUNT(*) c FROM estabelecimento;")$c
qt_socios   <- dbGetQuery(con, "SELECT COUNT(*) c FROM socios;")$c

cat("Otimizando (ANALYZE)...\n"); dbExecute(con, "ANALYZE;")

cat(strrep("-", 40), "\n")
cat(glue("Criado {db_path} (SQLite). Referência: {dataReferencia}\n"), "\n")
cat("Empresas (matrizes):", qt_empresas, "\n")
cat("Estabelecimentos:", qt_estab, "\n")
cat("Sócios:", qt_socios, "\n")
cat("FIM!!!", format(Sys.time()), "\n")

dbDisconnect(con)
