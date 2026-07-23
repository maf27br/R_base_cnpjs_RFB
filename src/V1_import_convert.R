#!/usr/bin/env Rscript
# -*- coding: utf-8 -*-
# Versão em R do script CNPJ_RFB_SQLITE.py
# Autor: adaptado por ChatGPT com base no script original do Marcio Freire
# Salve como CNPJ_RFB_SQLITE.R e execute (R 4.x)

library(rvest)
library(httr)
library(data.table)
library(DBI)
library(RSQLite)
library(glue)
library(fs)
library(stringi)

# --------- CONFIGURAÇÕES ----------
url_listagem <- "http://200.152.38.155/CNPJ/"  # onde ficam os .zip
pasta_compactados <- "./raw-data/"      # onde vão os .zip baixados
pasta_saida <- "./data/"                # onde os arquivos extraídos e o DB serão criados
dataReferencia <- "28/08/2025"                 # ajustar conforme necessário
# ----------------------------------

dir_create_if_missing <- function(path) {
  if (!dir_exists(path)) dir_create(path, recurse = TRUE)
}

dir_create_if_missing(pasta_compactados)
dir_create_if_missing(pasta_saida)

# Verifica se já existem zips na pasta de compactados
zips_exist <- length(dir_ls(pasta_compactados, glob = "*.zip")) > 0
if (zips_exist) {
  stop(glue("Há arquivos zip na pasta {pasta_compactados}. Apague ou mova esses arquivos zip e tente novamente"))
}

# 1) lista os arquivos .zip na URL
page <- tryCatch(read_html(url_listagem), error = function(e) {
  stop("Erro ao acessar a URL de listagem: ", conditionMessage(e))
})

anchors <- html_nodes(page, "a")
hrefs <- html_attr(anchors, "href")
# filtra por .zip
zip_paths <- hrefs[grepl("\\.zip$", hrefs, ignore.case = TRUE)]
if (length(zip_paths) == 0) stop("Nenhum .zip encontrado na página.")

# torna URLs absolutas se necessário
full_urls <- sapply(zip_paths, function(h) {
  if (grepl("^https?://", h, ignore.case = TRUE)) return(h)
  # alguns links são relativos
  return(url_absolute(h, url_listagem))
}, USE.NAMES = FALSE)

cat("Relação de Arquivos em", url_listagem, "\n")
for (u in full_urls) cat(u, "\n")

resp <- tolower(readline(prompt = glue("Deseja baixar os arquivos acima para a pasta {pasta_compactados} (y/n)? ")))
if (!(resp %in% c("y","s","yes","sim"))) {
  cat("Operação abortada pelo usuário.\n"); quit(status = 0)
}

# 2) faz o download dos zips
barra_progresso_download <- function(destfile, url) {
  # wrapper simples para download.file com mensagem
  cat("Baixando:", url, "->", destfile, "\n")
  tryCatch({
    download.file(url, destfile = destfile, mode = "wb", quiet = FALSE)
  }, error = function(e) {
    stop("Erro no download de ", url, ": ", conditionMessage(e))
  })
}

for (u in seq_along(full_urls)) {
  url_u <- full_urls[u]
  dest <- path(pasta_compactados, path_file(url_u))
  barra_progresso_download(dest, url_u)
}

cat("\nDownload finalizado.\n")

# 3) descompacta
zip_files <- dir_ls(pasta_compactados, glob = "*.zip")
if (length(zip_files) == 0) stop("Nenhum zip encontrado após o download.")

for (zf in zip_files) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "- descompactando", zf, "\n")
  unzip(zipfile = zf, exdir = pasta_saida)
}

# 4) cria o DB SQLite
db_path <- path(pasta_saida, "cnpj.db")
if (file_exists(db_path)) stop(glue("O arquivo {db_path} já existe. Apague-o primeiro e rode este script novamente."))

con <- dbConnect(RSQLite::SQLite(), dbname = db_path)
on.exit({
  try(dbDisconnect(con), silent = TRUE)
})

cat("Início:", format(Sys.time()), "\n")

# Função utilitária para carregar pequenas tabelas de código (.CNAECSV etc.)
carregaTabelaCodigo <- function(extensaoArquivo, nomeTabela) {
  files <- dir_ls(pasta_saida, regexp = paste0(extensaoArquivo, "$"), ignore.case = TRUE)
  if (length(files) == 0) {
    cat("Aviso: não encontrei arquivo", extensaoArquivo, "em", pasta_saida, "\n")
    return(invisible(NULL))
  }
  arquivo <- files[1]
  cat("carregando tabela", arquivo, "\n")
  dt <- fread(arquivo, sep = ";", header = FALSE, encoding = "Latin-1", col.names = c("codigo","descricao"), colClasses = "character")
  dbWriteTable(con, nomeTabela, dt, overwrite = TRUE, row.names = FALSE)
  dbExecute(con, glue("CREATE INDEX idx_{nomeTabela} ON {nomeTabela}(codigo);"))
}

carregaTabelaCodigo("\\.CNAECSV", "cnae")
carregaTabelaCodigo("\\.MOTICSV", "motivo")
carregaTabelaCodigo("\\.MUNICCSV", "municipio")
carregaTabelaCodigo("\\.NATJUCSV", "natureza_juridica")
carregaTabelaCodigo("\\.PAISCSV", "pais")
carregaTabelaCodigo("\\.QUALSCSV", "qualificacao_socio")

# 5) cria tabelas vazias com esquema (sem dados) - já que vamos inserir por append
sqlCriaTabela <- function(nomeTabela, colunas) {
  cols_def <- paste0(colunas, " TEXT", collapse = ",\n  ")
  sql <- glue("CREATE TABLE {nomeTabela} (\n  {cols_def}\n);")
  dbExecute(con, sql)
}

colunas_empresas <- c('cnpj_basico', 'razao_social',
                      'natureza_juridica',
                      'qualificacao_responsavel',
                      'capital_social_str',
                      'porte_empresa',
                      'ente_federativo_responsavel')

colunas_estabelecimento <- c('cnpj_basico','cnpj_ordem', 'cnpj_dv','matriz_filial',
                             'nome_fantasia',
                             'situacao_cadastral','data_situacao_cadastral',
                             'motivo_situacao_cadastral',
                             'nome_cidade_exterior',
                             'pais',
                             'data_inicio_atividades',
                             'cnae_fiscal',
                             'cnae_fiscal_secundaria',
                             'tipo_logradouro',
                             'logradouro',
                             'numero',
                             'complemento','bairro',
                             'cep','uf','municipio',
                             'ddd1', 'telefone1',
                             'ddd2', 'telefone2',
                             'ddd_fax', 'fax',
                             'correio_eletronico',
                             'situacao_especial',
                             'data_situacao_especial')

colunas_socios <- c('cnpj_basico',
                    'identificador_de_socio',
                    'nome_socio',
                    'cnpj_cpf_socio',
                    'qualificacao_socio',
                    'data_entrada_sociedade',
                    'pais',
                    'representante_legal',
                    'nome_representante',
                    'qualificacao_representante_legal',
                    'faixa_etaria')

colunas_simples <- c('cnpj_basico',
                     'opcao_simples',
                     'data_opcao_simples',
                     'data_exclusao_simples',
                     'opcao_mei',
                     'data_opcao_mei',
                     'data_exclusao_mei')

sqlCriaTabela("empresas", colunas_empresas)
sqlCriaTabela("estabelecimento", colunas_estabelecimento)
sqlCriaTabela("socios_original", colunas_socios)
sqlCriaTabela("simples", colunas_simples)

# 6) função para carregar tipos grandes: procura arquivos com a "extensão" e insere por append
carregaTipo <- function(nome_tabela, tipo_pattern, colunas) {
  # tipo_pattern é regex (ex: "\\.EMPRECSV$" ou "SIMPLES.CSV")
  arquivos <- dir_ls(pasta_saida, regexp = tipo_pattern, ignore.case = TRUE)
  if (length(arquivos) == 0) {
    cat("Nenhum arquivo para o padrão", tipo_pattern, "\n")
    return(invisible(NULL))
  }
  for (arq in arquivos) {
    cat("carregando:", arq, "\n")
    # ler com data.table::fread - dtype char (colClasses = "character")
    dt <- fread(arq, sep = ";", header = FALSE, encoding = "Latin-1", col.names = colunas, colClasses = "character", na.strings = "")
    # garante que existe pelo menos as colunas previstas
    missing_cols <- setdiff(colunas, names(dt))
    if (length(missing_cols) > 0) {
      for (mc in missing_cols) dt[[mc]] <- NA_character_
    }
    # grava no sqlite (append)
    dbWriteTable(con, nome_tabela, dt, append = TRUE, row.names = FALSE)
    rm(dt); gc()
    cat("fim parcial...", format(Sys.time()), "\n")
  }
}

}
# 7) Ajustes finais: capital_social (real), criar coluna cnpj em estabelecimento e indices
cat("Iniciando ajustes SQL finais...\n")

# 7.1 adiciona coluna capital_social e popula com conversão (troca , por .)
# SQLite aceita ALTER TABLE ADD COLUMN
dbExecute(con, "ALTER TABLE empresas ADD COLUMN capital_social real;")
# Atualiza substituindo vírgula por ponto e convertendo para real (CAST)
# Em SQLite: replace(...) -> troca; CAST(... AS REAL)
dbExecute(con, "UPDATE empresas SET capital_social = CAST(REPLACE(capital_social_str, ',', '.') AS REAL);")

# Para descartar a coluna capital_social_str (SQLite não tem DROP COLUMN antigo),
# cria uma nova tabela sem a coluna e copia dados
cat("Removendo coluna capital_social_str criando nova tabela temporária...\n")
cols_empresas_keep <- setdiff(colnames(dbGetQuery(con, "PRAGMA table_info(empresas);")), "capital_social_str")
# criar string de colunas para SELECT
cols_select <- paste(cols_empresas_keep, collapse = ", ")
dbExecute(con, glue("CREATE TABLE empresas_new AS SELECT {cols_select} FROM empresas;"))
dbExecute(con, "DROP TABLE empresas;")
dbExecute(con, "ALTER TABLE empresas_new RENAME TO empresas;")

# 7.2 adiciona coluna cnpj na tabela estabelecimento e popula
dbExecute(con, "ALTER TABLE estabelecimento ADD COLUMN cnpj TEXT;")
dbExecute(con, "UPDATE estabelecimento SET cnpj = cnpj_basico || cnpj_ordem || cnpj_dv;")

# 7.3 cria índices (se já existirem, ignora erros)
cria_idx_safe <- function(sql) {
  tryCatch({
    dbExecute(con, sql)
  }, error = function(e) {
    message("Aviso índice: ", conditionMessage(e))
  })
}

cria_idx_safe("CREATE INDEX idx_empresas_cnpj_basico ON empresas (cnpj_basico);")
cria_idx_safe("CREATE INDEX idx_empresas_razao_social ON empresas (razao_social);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_cnpj_basico ON estabelecimento (cnpj_basico);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_cnpj ON estabelecimento (cnpj);")
cria_idx_safe("CREATE INDEX idx_estabelecimento_nomefantasia ON estabelecimento (nome_fantasia);")
cria_idx_safe("CREATE INDEX idx_socios_original_cnpj_basico ON socios_original(cnpj_basico);")

# 8) cria tabela socios (matrizes) fazendo left join onde estabelecimento.matriz_filial = '1'
cat("Criando tabela socios a partir de socios_original e estabelecimento (matrizes)...\n")
# Para performance, cria tabela via SQL join (assumindo nomes iguais)
# Observação: se banco muito grande, essa operação pode levar tempo
dbExecute(con, "CREATE TABLE socios AS
  SELECT te.cnpj as cnpj, ts.*
  FROM socios_original ts
  LEFT JOIN estabelecimento te ON te.cnpj_basico = ts.cnpj_basico
  WHERE te.matriz_filial = '1';")

# remove socios_original para mimetizar o script python
dbExecute(con, "DROP TABLE IF EXISTS socios_original;")

# índices sobre socios
cria_idx_safe("CREATE INDEX idx_socios_cnpj ON socios(cnpj);")
cria_idx_safe("CREATE INDEX idx_socios_cnpj_cpf_socio ON socios(cnpj_cpf_socio);")
cria_idx_safe("CREATE INDEX idx_socios_nome_socio ON socios(nome_socio);")
cria_idx_safe("CREATE INDEX idx_socios_representante ON socios(representante_legal);")
cria_idx_safe("CREATE INDEX idx_socios_representante_nome ON socios(nome_representante);")
cria_idx_safe("CREATE INDEX idx_simples_cnpj_basico ON simples(cnpj_basico);")

# 9) Cria tabela _referencia e insere metadata
dbExecute(con, "CREATE TABLE IF NOT EXISTS _referencia (referencia TEXT, valor TEXT);")

qtde_cnpjs <- dbGetQuery(con, "SELECT COUNT(*) AS contagem FROM estabelecimento;")$contagem
dbExecute(con, "INSERT INTO _referencia (referencia, valor) VALUES (:ref, :val);",
          params = list(ref = "CNPJ", val = dataReferencia))
dbExecute(con, "INSERT INTO _referencia (referencia, valor) VALUES (:ref, :val);",
          params = list(ref = "cnpj_qtde", val = as.character(qtde_cnpjs)))

# 10) Mensagens finais com contagens
qt_empresas <- dbGetQuery(con, "SELECT COUNT(*) AS cont FROM empresas;")$cont
qt_estab <- dbGetQuery(con, "SELECT COUNT(*) AS cont FROM estabelecimento;")$cont
qt_socios <- dbGetQuery(con, "SELECT COUNT(*) AS cont FROM socios;")$cont

cat(strrep("-", 30), "\n")
cat(glue("Foi criado o arquivo {db_path}, com a base de dados no formato SQLITE.\n"))
cat("Qtde de empresas (matrizes):", qt_empresas, "\n")
cat("Qtde de estabelecimentos (matrizes e filiais):", qt_estab, "\n")
cat("Qtde de sócios:", qt_socios, "\n")
cat("FIM!!!", format(Sys.time()), "\n")

# desconecta
dbDisconnect(con)
