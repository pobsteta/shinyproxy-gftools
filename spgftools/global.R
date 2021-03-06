# if (!require("pacman")) install.packages("pacman")
# pacman::p_load(shiny,shinythemes,shinyjs,leaflet,ggvis,ggrepel,dplyr,RColorBrewer,raster,gstat,rgdal,Cairo,ggmap,ggplot2,DT,tools,leaflet.extras,pool,RPostgreSQL,devtools)
# pacman::p_load_gh('hadley/tidyverse','tidyverse/ggplot2','tidyverse/dplyr','r-spatial/sf','jrowen/rhandsontable')
# pacman::p_load_gh('pobsteta/gftools')

library(shiny)
library(shinythemes)
library(shinyjs)
library(leaflet)
library(ggvis)
library(ggrepel)
library(raster)
library(gstat)
library(rgdal)
library(Cairo)
library(ggmap)
library(ggplot2)
library(DT)
library(tools)
library(leaflet.extras)
library(pool)
library(RPostgreSQL)
library(gftools)
library(rhandsontable)
library(tibble)
library(tidyr)
library(RColorBrewer)
library(dplyr)
library(xtable)
library(sf)
library(yarrr)
library(grid)
library(pander)
library(captioner)
library(broom)
library(tidyverse)

## API google


## acces base de donnees
options(pgsql = list(
  "host" = "0.0.0.0",
  "port" = 35432,
  # "host" = "172.19.128.27",
  # "port" = 35432,
  "user" = "tryton",
  "password" = "tryton",
  "dbname" = "tryton"
))

## creation du pool de connexion
pool <- dbPool(
  drv = "PostgreSQL",
  port = options()$pgsql$port,
  dbname = options()$pgsql$dbname,
  host = options()$pgsql$host,
  user = options()$pgsql$user,
  password = options()$pgsql$password
)
onStop(function() {
  poolClose(pool)
})


# fichiers temporaires
mname <- tempfile(fileext = ".csv")
fname <- tempfile(fileext = ".csv")
cname <- tempfile(fileext = ".csv")
tname <- tempfile(fileext = ".csv")

# liste des tarifs
listetarif <- setNames(1:3, c("SR", "SL", "AL"))
listessence <- c("Defaut", "Chene", "Hetre", "Autres feuillus", "Epicea", "Sapin", "Pin", "Autres resineux")

# houppier compris
mhouppier <- "N"

# Vectorize TarONF3
TarifONF3v <- Vectorize(gftools::TarONF3)

# verifie le seuil des 16 connexions ouvertes autorisees
getConnection <- function(group) {
  if (!exists(".connection", where = .GlobalEnv)) {
    .connection <<- dbConnect("PostgreSQL",
      dbname = options()$pgsql$dbname, host = options()$pgsql$host,
      port = options()$pgsql$port, user = options()$pgsql$user,
      password = options()$pgsql$password, group = group
    )
  } else if (class(try(dbGetQuery(.connection, "SELECT 1"))) == "try-error") {
    dbDisconnect(.connection)
    .connection <<- dbConnect("PostgreSQL",
      dbname = options()$pgsql$dbname, host = options()$pgsql$host,
      port = options()$pgsql$port, user = options()$pgsql$user,
      password = options()$pgsql$password, group = group
    )
  }
  return(.connection)
}

#' BDDQueryONF
#'
#' @param query = requête au format SQL en texte
#'
#' @return Le résultat de la requête sur la base de données
#'
#' @examples
#' BDDQueryONF(query = "SELECT ccod_cact, ccod_frt, llib2_frt, geom FROM forest")
BDDQueryONF <- function(query) {
  ## query posgresql database onf
  # set up connection
  conn <- dbConnect("PostgreSQL",
    dbname = options()$pgsql$dbname, host = options()$pgsql$host,
    port = options()$pgsql$port, user = options()$pgsql$user,
    password = options()$pgsql$password
  )
  # dummy query (obviously), including a spatial subset and ST_Simplify to simplify geometry (optionel)
  result <- sf::st_read(conn, query = query) %>%
    sf::st_transform(result, crs = 4326)
  dbDisconnect(conn)
  return(result)
}

#' delData
#'
#' @param data
#'
#' @return
#' @export
#'
#' @examples
delData <- function(query) {
  pool::dbGetQuery(pool, query)
}

#' saveData
#'
#' @param data
#'
#' @return
#' @export
#'
#' @examples
saveData <- function(query) {
  pool::dbGetQuery(pool, query)
}


#' loadData
#'
#' @param query
#'
#' @return
#' @export
#'
#' @examples
loadData <- function(query) {
  if (length(query) == 0) {
    return(NULL)
  } else {
    data <- pool::dbGetQuery(pool, query)
    return(data)
  }
}


#' insertData
#'
#' @param table
#' @param df
#'
#' @return
#' @export
#'
#' @examples
insertData <- function(table, df) {
  dbWriteTable(pool, table, df, append = TRUE, row.names = FALSE)
}


# Data
dtdata <- BDDQueryONF(query = "SELECT id, iidtn_dt, llib_dt, geom FROM dt ORDER BY iidtn_dt")
agencedata <- BDDQueryONF(query = "SELECT id, iidtn_agc, llib_agc, geom FROM agence ORDER BY iidtn_agc")
forestdata <- BDDQueryONF(query = "SELECT id, ccod_cact, ccod_frt, llib2_frt, geom FROM forest ORDER BY ccod_frt")
parcelledata <- BDDQueryONF(query = "SELECT id, ccod_cact, ccod_frt, llib_frt, ccod_prf, ccod_pst, geom FROM parcelle ORDER BY iidtn_prf")
pstdata <- BDDQueryONF(query = "SELECT ccod_cact, ccod_ut, clib_pst, geom FROM pst ORDER BY ccod_ut")
files <- loadData("SELECT s.id AS id, d.iidtn_dt AS dt, a.iidtn_agc AS agence, f.ccod_frt AS forest, p.ccod_prf AS parcelle 
                  FROM sample s, dt d, agence a, forest f, parcelle p 
                  WHERE s.dt=d.id AND s.agence=a.id AND s.forest=f.id AND s.parcelle=p.id")
filed <- loadData("SELECT * FROM filedata")
filem <- loadData("SELECT * FROM filemercuriale")
filec <- loadData("SELECT * FROM cahierclausedt")

#' BestTarifFindSch
#'
#' @param decemerge
#' @param typvolemerge
#' @param zonecalc
#' @param clause
#' @param essence
#' @param classearbremin
#' @param classearbremax
#' @param barre
#' @param agence
#' @param exercice
#' @param typzonecalc
#' @param mercuriale
#' @param categorie
#'
#' @return
#' @export
#'
#' @examples
BestTarifFindSch <- function(mercuriale = NULL, decemerge = 7, typvolemerge = "total", zonecalc = NULL,
                             clause = NULL, categorie = NULL,
                             essence = c("02", "09"), classearbremin = 20, classearbremax = 80,
                             barre = NULL, agence = 8415, exercice = 17, typzonecalc = "ser") {
  split <- function(texte) {
    strsplit(texte, " ")[[1]][1]
  }
  splitv <- Vectorize(split)
  TarONF3v <- Vectorize(gftools::TarONF3)
  message("Extract mercuriale file...")
  if (!is.null(mercuriale)) {
    mer <- readr::read_tsv(
      mercuriale,
      locale = readr::locale(encoding = "UTF-8", decimal_mark = "."),
      readr::cols(cdiam = readr::col_integer(), tarif = readr::col_character(), houppier = readr::col_integer(), hauteur = readr::col_double()),
      col_names = T
    ) %>%
      filter(!is.na(tarif))
  } else {
    mer <- data.frame(cdiam = seq(from = 10, to = 120, by = 5), tarif = rep("SR14", 23), houppier = c(rep(0, 3), rep(30, 20)), hauteur = rep(0, 23))
  }
  message("Extract clause file...")
  if (!is.null(clause)) {
    clo <- readr::read_tsv(
      clause,
      locale = readr::locale(encoding = "UTF-8", decimal_mark = "."),
      readr::cols(ess = readr::col_character(), dmin = readr::col_integer(), dmax = readr::col_integer(), dec = readr::col_double()),
      col_names = T
    )
  } else {
    clo <- as_tibble(data.frame(ess = "Defaut", dmin = 10, dmax = 200, dec = 7, stringsAsFactors = FALSE))
  }
  message("Extract categorie file...")
  if (!is.null(categorie)) {
    categorie <- readr::read_tsv(
      categorie,
      locale = readr::locale(encoding = "UTF-8", decimal_mark = "."),
      readr::cols(ess = readr::col_character(), cat = readr::col_character(), dmin = readr::col_integer(), dmax = readr::col_integer()),
      col_names = T
    )
  } else {
    categorie <- data.frame(
      ess = rep(c("Feu", "Res"), times = 1, each = 6),
      cat = rep(c("Sem", "Per", "PB", "BM", "GB", "TGB"), times = 2),
      dmin = c(0, 10, 20, 30, 50, 70, 0, 10, 20, 30, 45, 65),
      dmax = c(5, 15, 25, 45, 65, 200, 5, 15, 25, 40, 60, 200),
      stringsAsFactors = FALSE
    )
  }
  message("Extract IFN data...")
  vecteur_annee <- c(2008:2016)
  dossier <- system.file("extdata/IFN", package = "gftools")
  # Extract placettes et arbres
  message("Extract data placettes...")
  plac <- data.frame()
  for (i in 1:length(vecteur_annee)) {
    yrs <- as.numeric(vecteur_annee[i])
    ifn <- gftools::getFich_IFN(obj = c("Pla"), Peup = FALSE, Morts = FALSE, Doc = TRUE, ans = yrs, doss = dossier)
    placet <- data.frame(yrs = yrs, ifn$Pla[[1]][, c("idp", "ser", "xl93", "yl93")])
    plac <- rbind(plac, placet)
  }
  message("Extract data arbres...")
  arb <- data.frame()
  for (i in 1:length(vecteur_annee)) {
    yrs <- as.numeric(vecteur_annee[i])
    ifn <- gftools::getFich_IFN(obj = c("Arb"), Peup = FALSE, Morts = FALSE, Doc = TRUE, ans = yrs, doss = dossier)
    arbre <- data.frame(yrs = yrs, ifn$Arb[[1]][, c("idp", "espar", "c13", "w", "htot", "hdec", "veget")])
    arb <- rbind(arb, arbre)
  }
  message(paste0("Extract data zonecalc: ", toupper(typzonecalc), "..."))
  zone <- sf::st_transform(zonecalc, crs = 2154)
  codereg <- unique(zone["code"]$code)
  listres <- vector("list", length(codereg))
  nreg <- length(codereg)
  for (reg in 1:nreg) {
    regzone <- zone["code"] %>% dplyr::filter(code == codereg[reg])
    message(paste0("Calcul pour la zone ", toupper(typzonecalc), " : ", codereg[reg], " (", reg, "/", nreg, ")"))
    placettes <- sf::st_intersection(sf::st_as_sf(plac, coords = c("xl93", "yl93"), crs = 2154, agr = "constant"), sf::st_geometry(regzone))
    # premier tableau data arbres
    tab <- arb %>%
      dplyr::filter(espar %in% essence) %>%
      # dplyr::filter(espar %in% c("02","03","09","17C","52","54","61","62","64","65")) %>%
      dplyr::filter(idp %in% placettes$idp) %>%
      dplyr::filter(veget == "0") %>%
      dplyr::select(espar, c13, htot, hdec) %>%
      dplyr::mutate(diam = round(c13 / pi, 0)) %>%
      dplyr::mutate(espar = as.character(espar)) %>%
      dplyr::left_join(gftools::code_ifn_onf, by = c(espar = "espar")) %>%
      dplyr::filter(!is.na(htot)) %>%
      dplyr::mutate(
        esscct = ifelse(splitv(essence) %in% c("Hetre", "Chene", "Pin"), splitv(essence), fr),
        ess = ifelse(fr == "Autres feuillus", "Feu", "Res")
      )
    ## verifie si tab est vide = pas de data essence pour la region
    if (nrow(tab) == 0) {
      next
    }
    ## creation des tableaux
    tab <- tab %>%
      dplyr::mutate(Classe = as.integer(floor(diam / 5 + 0.5) * 5)) %>%
      dplyr::inner_join(mer, by = c(Classe = "cdiam"))
    ## recherche la decoupe emerge dans les clauses ou prend decemerge
    defo <- ifelse(!is.null(clause), clo[clo$ess %in% "Defaut", "dec"][[1]], decemerge)
    # on gere les essences essence
    tab.0 <- tab %>% 
      dplyr::left_join(clo, by = c(essence = "ess")) %>% 
      dplyr::filter(
        !is.na(dec),
        Classe >= dmin & Classe <= dmax
      ) 
    # on gere les essences regroupees dans les clauses (Chene, Pin)
    tab.1 <- tab %>% 
      dplyr::left_join(clo, by = c(essence = "ess")) %>% 
      dplyr::filter(is.na(dec)) %>% 
      dplyr::select(-dmin, -dmax, -dec) %>% 
      dplyr::mutate(clo = splitv(esscct)) %>%
      dplyr::left_join(clo, by = c(clo = "ess")) %>% 
      dplyr::filter(
        !is.na(dec),
        Classe >= dmin & Classe <= dmax
      ) 
    # on gere les essences Autres
    tab.2 <- tab %>% 
      dplyr::left_join(clo, by = c(essence = "ess")) %>% 
      dplyr::filter(is.na(dec)) %>% 
      dplyr::select(-dmin, -dmax, -dec) %>% 
      dplyr::mutate(clo = splitv(esscct)) %>%
      dplyr::left_join(clo, by = c(clo = "ess")) %>% 
      dplyr::filter(is.na(dec)) %>% 
      dplyr::select(-dmin, -dmax, -dec) %>% 
      dplyr::left_join(clo, by = c(fr = "ess")) %>% 
      dplyr::filter(
        !is.na(dec),
        Classe >= dmin & Classe <= dmax
      ) 
    # on gere essence Defaut
    tab.3 <- dplyr::anti_join(tab, dplyr::bind_rows(tab.0, tab.1, tab.2)) %>% 
      mutate(
        dmin = clo[1, 2]$dmin,
        dmax = clo[1, 3]$dmax,
        dec = clo[1, 4]$dec
      ) %>% 
      dplyr::filter(
        !is.na(dec),
        Classe >= dmin & Classe <= dmax
      ) 
    # on merge
    tab <- dplyr::bind_rows(tab.0, tab.1, tab.2, tab.3) %>% 
      dplyr::mutate(
        defaut = defo,
        decemerge = ifelse(!is.na(dmin) & Classe >= dmin, dec, defaut)
      ) %>% 
      dplyr::select(espar, essence, ess, diam, Classe, htot, hdec, decemerge, tarif, hauteur, houppier)
    tab <- cbind(tab, E_VbftigCom = TarEmerge(c130 = pi * tab$diam, htot = tab$htot, hdec = tab$hdec, espar = tab$espar, typevol = "tige", dec = tab$decemerge))
    tab <- cbind(tab, E_Vbftot7cm = TarEmerge(c130 = pi * tab$diam, htot = tab$htot, hdec = tab$hdec, espar = tab$espar, typevol = "total", dec = 7)) %>%
      dplyr::mutate(E_PHouppiers = E_Vbftot7cm / E_VbftigCom - 1) %>%
      dplyr::filter(!is.na(E_Vbftot7cm)) %>%
      dplyr::mutate(E_VHouppiers = E_Vbftot7cm - E_VbftigCom)
    tab1 <- tab %>%
      mutate("Essence_Hou" = paste(tab$essence, "Hou", sep = "_")) %>%
      dplyr::select(Essence_Hou, Classe, E_PHouppiers) %>%
      dplyr::mutate_if(is.numeric, funs(round(., 2))) %>%
      group_by(Classe, Essence_Hou) %>%
      summarise_at(c("E_PHouppiers"), funs(mean)) %>%
      mutate_at(c("E_PHouppiers"), funs(as.integer(round(100 * . / (1 + .), 0)))) %>%
      arrange(Essence_Hou, Classe) %>%
      spread(Essence_Hou, E_PHouppiers)
    # tableau par categorie (PB,BM,GB,TGB)
    tab <- tab %>%
      left_join(categorie, by = c(ess = "ess")) %>%
      filter(Classe >= dmin & Classe <= dmax) %>%
      dplyr::filter(diam >= classearbremin & diam <= classearbremax) %>%
      dplyr::mutate(
        numSchR = E_Vbftot7cm / 5 * 70000 / (diam - 5) / (diam - 10) - 8,
        numSchL = E_Vbftot7cm / 5 * 90000 / diam / (diam - 5) - 8,
        numAlg = E_Vbftot7cm * 28000000 / (310000 - 45200 * diam + 2390 * diam^2 - 2.9 * diam^3) - 8
      )
    tab.h <- tab %>%
      dplyr::select(essence, diam, Classe, htot, E_Vbftot7cm, numSchR, numSchL, numAlg) %>%
      tidyr::gather(Type, Num, -essence, -diam, -Classe, -htot, -E_Vbftot7cm) %>%
      dplyr::mutate(Type = factor(Type, levels = c("numSchR", "numSchL", "numAlg"))) %>%
      dplyr::mutate(Classe = factor(Classe))
    p <- c(0.10, 0.35, 0.65, 0.90)
    p_names <- purrr::map_chr(p, ~paste0(.x*100))
    p_fh <- purrr::map(p, ~partial(quantile, probs = .x, na.rm = TRUE)) %>%
      purrr::set_names(nm = paste0("h",p_names))
    p_fn <- purrr::map(p, ~partial(quantile, probs = .x, na.rm = TRUE)) %>%
      purrr::set_names(nm = paste0("n",p_names))
    tab.h1 <- tab.h %>%
      group_by(essence, Classe, Type) %>%
      summarize_at(vars(htot), funs(!!!p_fh))
    tab.h2 <- tab.h %>%
      group_by(essence, Classe, Type) %>%
      summarize_at(vars(Num), funs(!!!p_fn))
    tab.n <- merge(tab.h1, tab.h2)
    res <- tab %>%
      dplyr::group_by(essence, cat) %>%
      dplyr::summarise_at(c("numSchR", "numSchL", "numAlg"), funs(mean, var))
    res[, 6:8] <- round(res[, 6:8]^0.5 / res[, 3:5], 3)
    res[, 3:5] <- round(res[, 3:5], 3)
    names(res) <- c("essence", "categorie", "SR", "SL", "AL", "SRcv", "SLcv", "ALcv")
    tab2 <- as.data.frame(res) %>%
      dplyr::mutate(
        tar = names(.)[max.col(.[6:8] * -1) + 2L],
        Best_tarif = case_when(
          tar == "SR" ~ paste0("SR", as.character(formatC(round(.[, c("SR")], 0), width = 2, flag = "0"))),
          tar == "SL" ~ paste0("SL", as.character(formatC(round(.[, c("SL")], 0), width = 2, flag = "0"))),
          tar == "AL" ~ paste0("AL", as.character(formatC(round(.[, c("AL")], 0), width = 2, flag = "0")), "+")
        )
      ) %>%
      dplyr::select(essence, categorie, SR, SL, AL, SRcv, SLcv, ALcv, Best_tarif)

    tab3 <- tab %>%
      dplyr::distinct(essence, Classe, cat) %>%
      group_by(Classe, essence, cat) %>%
      dplyr::right_join(tab2[, c("essence", "Best_tarif", "categorie")], by = c(essence = "essence", cat = "categorie")) %>%
      dplyr::ungroup()

    tab4 <- tab3 %>%
      dplyr::mutate("Essence_Tar" = paste(tab3$essence, "Tar", sep = "_")) %>%
      dplyr::select(Essence_Tar, Classe, Best_tarif) %>%
      arrange(Essence_Tar, Classe) %>%
      spread(Essence_Tar, Best_tarif)
    tab5 <- merge(tab1, tab4)
    # calcul des graphes des essences comparant Best EMERGE avec LOCAL de ProdBois
    ness <- length(essence)
    # ness <- 10
    lres <- vector("list", ness)
    for (sp in 1:ness) {
      if (!is.null(barre)) {
        barre$set(value = ness * (reg - 1) + sp)
      }
      species <- essence[sp]
      codess <- gftools::code_ifn_onf %>%
        filter(espar == species) %>%
        pull(code)
      nomess <- gftools::code_ifn_onf %>%
        filter(espar == species) %>%
        pull(essence)
      message(paste0("Graphe de l'essence : ", nomess, " (", species, " - ", sp, "/", ness, ")"))
      mercuess <- tab5 %>%
        dplyr::select(Classe, starts_with(nomess))
      mercuess$haut <- 0
      if (length(mercuess) == 4) {
        names(mercuess) <- c("cdiam", "houppier", "tarif", "hauteur")
      } else {
        next
      }
      if (species %in% c("02")) {
        qess <- "(ess='CHP' OR ess='CHX')"
      } else if (species %in% c("03")) {
        qess <- "(ess='CHS' OR ess='CHX')"
      } else if (species %in% c("61")) {
        qess <- "(ess='SAP' OR ess='S.P')"
      } else {
        qess <- paste0("ess='", codess, "'")
      }
      cc <- codereg[reg]
      idreg <- zone %>% filter(code == cc) %>% pull(id) %>% paste(., collapse = ",")
      query <- sprintf(
        "SELECT exercice, agence, ess AS essence, diam, haut, nb, tahd AS l_phouppiers, tacomd, volcu AS l_vbftigcom, volcu*(tahd/100.0) AS l_vhouppiers, 
                volcu*(1+tahd/100.0) AS l_vbftot7cm FROM datacab d, forest f, %s r WHERE agence='%s' AND exercice=%s AND diam>0 AND tacomd!='0' AND %s
                AND cofrt=ccod_frt AND agence=ccod_cact AND st_intersects(f.geom,r.geom) AND r.id IN (%s)",
        typzonecalc, agence, exercice, qess, idreg
      )
      res <- loadData(query = query)
      if (!is.null(res)) {
        if (nrow(res) > 0) {
          res <- res %>%
            mutate(classe = floor(diam / 5 + 0.5) * 5) %>%
            inner_join(mercuess, by = c(classe = "cdiam"))
          tab <- res %>%
            mutate(
              e_vbftot7cm = as.numeric(TarifONF3v(tarif = tarif, entr1 = diam, entr2 = haut, details = FALSE)),
              e_vhouppiers = e_vbftot7cm * houppier / 100,
              e_vbftigcom = e_vbftot7cm - e_vhouppiers,
              e_phouppiers = houppier / 100
            )
          # on ne veut q'une essence
          if (species %in% c("02", "03")) {
            tab$essence <- "CHX"
          } else if (species %in% c("61")) {
            tab$essence <- "SAP"
          } else {
            tab$essence <- codess
          }
          tab.r <- tab %>%
            mutate(tl_vbftigcom = l_vbftigcom * nb, tl_vhouppiers = l_vhouppiers * nb, te_vbftigcom = e_vbftigcom * nb, te_vhouppiers = e_vhouppiers * nb) %>%
            group_by(exercice, agence, essence, classe) %>%
            summarise_at(c("tl_vbftigcom", "tl_vhouppiers", "te_vbftigcom", "te_vhouppiers", "nb"), sum, na.rm = TRUE)
          resv <- gftools::describeBy(tab.r, group = tab.r$essence)
          txt <- paste0("ESSENCE ", nomess, " - AGENCE ", tab.r$agence[1], " - EXERCICE ", tab.r$exercice[1], " : ")
          for (r in length(resv):1) {
            txt[2] <- paste0("Pour l'essence ", names(resv[r]), ",")
            txt[3] <- paste0(
              " l'estimation L (LOCAL) cube ", round(100 * ((resv[[r]]["tl_vbftigcom", "sum"] + resv[[r]]["tl_vhouppiers", "sum"]) /
                (resv[[r]]["te_vbftigcom", "sum"] + resv[[r]]["te_vhouppiers", "sum"]) - 1), 0),
              "% du volume bois fort total decoupe 7cm E (EMERCU), ", round(100 * (resv[[r]]["tl_vbftigcom", "sum"] / resv[[r]]["te_vbftigcom", "sum"] - 1), 0),
              "% du volume bois fort tige E et ", round(100 * (resv[[r]]["tl_vhouppiers", "sum"] / resv[[r]]["te_vhouppiers", "sum"] - 1), 0),
              "% du volume houppiers E ("
            )
            txt[4] <- paste0(
              "le volume bois fort tige commercial L est de ", round(resv[[r]]["tl_vbftigcom", "sum"], 0),
              " m3, le volume bois fort tige commercial E est de ", round(resv[[r]]["te_vbftigcom", "sum"], 0),
              " m3,"
            )
            txt[5] <- paste0(
              "le volume houppier L est de ", round(resv[[r]]["tl_vhouppiers", "sum"], 0),
              " m3 et le volume houppier E est de ", round(resv[[r]]["te_vhouppiers", "sum"], 0), " m3."
            )
          }
          txt[6] <- paste0("Les tarifs locaux utilisés sont : ", paste(unique(res$tacomd), collapse = ", "), ".")
          table1 <- tab.r %>%
            dplyr::select(exercice, agence, essence, classe, tl_vbftigcom, tl_vhouppiers, te_vbftigcom, te_vhouppiers) %>%
            dplyr::mutate(
              voltot_E = te_vbftigcom + te_vhouppiers,
              voltot_L = tl_vbftigcom + tl_vhouppiers,
              vbftigcom_L_E = 100 * (tl_vbftigcom / te_vbftigcom - 1),
              vhouppiers_L_E = 100 * (tl_vhouppiers / te_vhouppiers - 1),
              voltot_L_E = 100 * (voltot_L / voltot_E - 1)
            )
          names(table1) <- c(
            "exercice", "agence", "essence", "classe", "vbftigcom_L", "vhouppiers_L", "vbftigcom_E", "vhouppiers_E", "voltot_E", "voltot_L",
            "%_vbftigcom_L_E", "%_vhouppiers_L_E", "%_voltot_L_E"
          )
          table2 <- table1 %>%
            gather("typvol", "vol", 5:13)
          table3 <- table2 %>%
            dplyr::mutate("Class" = as.character(formatC(table2$classe, width = 3, flag = "0"))) %>%
            dplyr::select(exercice, agence, essence, Class, typvol, vol) %>%
            arrange(Class) %>%
            spread(Class, vol) %>%
            mutate_if(is.numeric, funs(round(., 0)))

          table4 <- as.data.frame(table3[, -c(1:3)])
          table5 <- cbind(table4, Total = rowSums(table4[, -c(1)]))
          table5$Total[1] <- 100 * (table5$Total[5] / table5$Total[4] - 1)
          table5$Total[2] <- 100 * (table5$Total[7] / table5$Total[6] - 1)
          table5$Total[3] <- 100 * (table5$Total[9] / table5$Total[8] - 1)
          table5 <- table5 %>%
            mutate_if(is.numeric, funs(round(., 0)))
          tab.t <- reshape2::melt(tab.r, id.vars = c("exercice", "agence", "essence", "classe"), measure.vars = c("tl_vbftigcom", "tl_vhouppiers", "te_vbftigcom", "te_vhouppiers")) %>%
            mutate(Type = substr(variable, 1, 2), variable = substr(variable, 4, 12))
          names(tab.t) <- c("exercice", "agence", "essence", "classe", "tarif", "vol", "type")
          tab.t$type[which(tab.t$type == "tl")] <- "L"
          tab.t$type[which(tab.t$type == "te")] <- "E"
          tab.t$tarif[which(tab.t$tarif == "vhouppier")] <- "VHouppiers"
          tab.t$tarif[which(tab.t$tarif == "vbftigcom")] <- "VbftigCom"
          p <- ggplot(tab.t, aes(x = type, y = vol, group = type, fill = type, alpha = tarif)) +
            scale_fill_manual(values = c("red", "darkgreen")) +
            geom_bar(stat = "identity", position = "stack") +
            facet_grid(agence + essence ~ classe) +
            scale_alpha_manual(values = c(1, 0.1))
          tabo <- tab.n[which(tab.n$essence %in% c(nomess)), ] 
          tab.a <- tabo %>% 
            arrange(essence, Type, Classe)
          classd <- as.numeric(levels(tabo$Classe))[tabo$Classe]
          q <- ggplot() +
            geom_point(data = tab.h[which(tab.h$essence %in% c(nomess)), ], aes(x = diam, y = htot)) + 
            facet_grid(Type ~ .) +
            ggtitle(nomess) +
            geom_smooth(data = tabo, 
                        aes(x = classd, y = h10), 
                        span = 1, method = "loess", se = TRUE, alpha = 0.2, size = 0.5, col = "red") +
            geom_label_repel(data = tabo,
                             aes(x = classd, y = h10, label = round(n10, digits = 0)), col = "red", size = 2.5) +
            geom_smooth(data = tabo,
                        aes(x = classd, y = h35), 
                        span = 1, method = "loess", se = TRUE, alpha = 0.2, size = 0.5) +
            geom_label_repel(data = tabo,
                             aes(x = classd, y = h35, label = round(n35, digits = 0)), size = 2.5) +
            geom_smooth(data = tabo,
                        aes(x = classd, y = h65), 
                        span = 1, method = "loess", se = TRUE, alpha = 0.2, size = 0.5, col = "red") +
            geom_label_repel(data = tabo,
                             aes(x = classd, y = h65, label = round(n65, digits = 0)), col = "red", size = 2.5) +
            geom_smooth(data = tabo,
                        aes(x = classd, y = h90), 
                        span = 1, method = "loess", se = TRUE, alpha = 0.2, size = 0.5) +
            geom_label_repel(data = tabo,
                             aes(x = classd, y = h90, label = round(n90, digits = 0)), size = 2.5) +
            theme(legend.position="none")
          lres[[sp]] <- list(tab.r, p, txt, table5, tab.h, tab.a, q)
          names(lres[[sp]]) <- c("Tableau3", "Graphe1", "Texte", "Tableau4", "Tableau5", "Tableau6", "Graphe2")
        }
      }

      # uniquement la région
      creg <- codereg[reg]
      m <- zone %>%
        dplyr::filter(code == creg)
      poste <- BDDQueryONF(query = paste0("SELECT ccod_cact, ccod_ut, clib_pst, geom FROM pst WHERE ccod_ut LIKE '", agence, "%' ORDER BY ccod_ut"))
      pst <- sf::st_intersection(m, sf::st_transform(poste, crs = 2154)) %>%
        fortify()
      pstbbox <- sf::st_bbox(pst)
      carte <- ggplot() +
        ggplot2::geom_sf(data = sf::st_as_sf(m)) +
        ggplot2::geom_sf(data = pst, aes(fill = ccod_ut)) +
        scale_fill_brewer(palette = "Set3", name = "Poste") +
        labs(title = paste("Agence - ", agence, " : ", pst$code[1], "-", pst$reg[1])) +
        coord_sf(xlim = c(pstbbox[[1]], pstbbox[[3]]), ylim = c(pstbbox[[2]], pstbbox[[4]])) +
        theme(
          axis.text = element_blank(),
          line = element_blank(),
          plot.title = element_text(size = 10, color = "DarkGreen")
        )
      listres[[reg]] <- list(tab5, tab2, lres, carte)
      names(listres[[reg]]) <- c("Tableau1", "Tableau2", "Species", "Carte")
    }
  }
  message("...Calculation realized!")
  return(listres)
}


#' rquery.t.test
#'
#' @param x : un vecteur non vide de valeurs
#' @param y : un vecteur optionnel non vide de valeurs
#' @param paired : si TRUE, le t-test indépendant est utilise
#' @param graph : si TRUE, la distribution des donnees est représenté pour
#' tester la normalite des donnees
#' @param ... : plusieurs arguments qui sont passes a la fonction t.test() de R
# 1. shapiro.test est utilise pour verifier la normalite
# 2. F-test est utilise pour verifier les variances
# Si les variances sont differentes alors le Welch t-test est utilise
#'
#' @return list
#' @export
#'
#' @examples
#' 
rquery.t.test <- function(df1, df2 = NULL, paired = FALSE,
                          graph = TRUE, ...) {
  # I. Premier test : normalite et variance
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  var.equal <- FALSE # par defaut
  x <- df1$Num
  y <- df2$Num
  nomx <- unique(df1$group)
  nomy <- unique(df2$group)

  # I.1 un jeu de donnee
  if (is.null(y)) {
    if (graph) par(mfrow = c(1, 2))
    shapiro.px <- normaTest(x, graph,
      hist.title = paste(nomx, "- Histogram"),
      qq.title = paste(nomx, "- Normal Q-Q Plot")
    )
    if (shapiro.px < 0.05) {
      shap <- paste(
        nomx, "ne suit pas une distribution normale :",
        "Shapiro-Wilk test p-value : ", shapiro.px,
        ".\n Utilisez le test non-paramétrique de Wilcoxon."
      )
    } else {
      shap <- paste(nomx, "suit une distribtuion normale.")
    }
  }

  # I.2 deux jeux de donnees
  if (!is.null(y)) {
    if (!paired) { # I.2.a unpaired t test
      if (graph) par(mfrow = c(2, 2))
      # normality test
      shapiro.px <- normaTest(x, graph,
        hist.title = paste(nomx, "- Histogram"),
        qq.title = paste(nomx, "- Normal Q-Q Plot")
      )
      shapiro.py <- normaTest(y, graph,
        hist.title = paste(nomy, "- Histogram"),
        qq.title = paste(nomy, "- Normal Q-Q Plot")
      )
      if (shapiro.px < 0.05 & shapiro.py < 0.05) {
        shap <- paste(
          nomx, "et", nomy, "ne suivent pas une distribution normale :",
          " Shapiro test p-value : ", shapiro.px,
          " (pour", nomx, ") et", shapiro.py, " (pour", nomy, ")",
          ".\n Utilisez un test non paramétrique de type Wilcoxon."
        )
      } else if (shapiro.px < 0.05 & shapiro.py >= 0.05) {
        shap <- paste(
          nomx, "ne suit pas une distribution normale :",
          "Shapiro-Wilk test p-value : ", shapiro.px,
          ".\n Utilisez le test non-paramétrique de Wilcoxon."
        )
      } else if (shapiro.px >= 0.05 & shapiro.py < 0.05) {
        shap <- paste(
          nomy, "ne suit pas une distribution normale :",
          "Shapiro-Wilk test p-value : ", shapiro.py,
          ".\n Utilisez le test non-paramétrique de Wilcoxon."
        )
      } else {
        shap <- paste(nomx, "et", nomy, "suivent une distribution normale.")
      }
    }
    # Verifie l egalite des variances
    if (var.test(x, y)$p.value >= 0.05) {
      var.equal <- TRUE
    }
  } else { # I.2.b Paired t-test
    if (graph) par(mfrow = c(1, 2))
    d <- x - y
    shapiro.pd <- normaTest(d, graph,
      hist.title = paste(nomx, "~", nomy, "- Histogram"),
      qq.title = paste(nomx, "~", nomy, "- Normal Q-Q Plot")
    )
    if (shapiro.pd < 0.05) {
      shap <- paste(
        "La différence", nomx, "~ ", nomy, "ne suit pas une distribution normale :",
        " Shapiro-Wilk test p-value : ", shapiro.pd,
        ".\n Utilisez un test non-paramétrique de type Wilcoxon."
      )
    } else {
      shap <- paste(nomx, "et", nomy, "suivent une distribution normale.")
    }
  }

  # II. Student's t-test
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  res <- t.test(x, y, paired = paired, var.equal = var.equal, ...)
  out <- list(shap, res)
  names(out) <- c("shapiro", "test")
  return(out)
}

#' normaTest
#'
#' @param x : un jeu de donnees non vide
#' @param graph : les valeurs possibles sont TRUE ou FALSE. Si TRUE,
#  l histogramme et le Q-Q plot des donnes sont affcihes
#' @param hist.title  : titre de l histogram
#' @param qq.title : titre du Q-Q plot
#' @param ...
#'
#' @return
#' @export
#'
#' @examples
#' 
normaTest <- function(x, graph = TRUE,
                      hist.title = "Histogramme",
                      qq.title = "Normal Q-Q Plot", ...) {
  # Significance test
  #++++++++++++++++++++++
  shapiro.p <- signif(shapiro.test(x)$p.value, 1)

  if (graph) {
    # Plot : Visual inspection
    #++++++++++++++++
    h <- hist(x,
      col = "lightblue", main = hist.title,
      xlab = "Numéro de tarif", ...
    )
    m <- round(mean(x), 1)
    s <- round(sd(x), 1)
    mtext(paste0("Moy : ", m, " - SD : ", s),
      side = 3, cex = 0.8
    )
    # add normal curve
    xfit <- seq(min(x), max(x), length = 40)
    yfit <- dnorm(xfit, mean = mean(x), sd = sd(x))
    yfit <- yfit * diff(h$mids[1:2]) * length(x)
    lines(xfit, yfit, col = "red", lwd = 2)
    # qq plot
    qqnorm(x, pch = 19, frame.plot = FALSE, main = qq.title)
    qqline(x)
    mtext(paste0("Shapiro-Wilk, p-val : ", shapiro.p),
      side = 3, cex = 0.8
    )
  }
  return(shapiro.p)
}

#' multiplot
#'
#' @param ... 
#' @param plotlist 
#' @param cols 
#'
#' @return
#' @export
#'
#' @examples
multiplot <- function(..., plotlist=NULL, cols) {
  # Make a list from the ... arguments and plotlist
  plots <- c(list(...), plotlist)
  
  numPlots = length(plots)
  
  # Make the panel
  plotCols = cols                          # Number of columns of plots
  plotRows = ceiling(numPlots/plotCols) # Number of rows needed, calculated from # of cols
  
  # Set up the page
  grid.newpage()
  pushViewport(viewport(layout = grid.layout(plotRows, plotCols)))
  vplayout <- function(x, y)
    viewport(layout.pos.row = x, layout.pos.col = y)
  
  # Make each plot, in the correct location
  for (i in 1:numPlots) {
    curRow = ceiling(i/plotCols)
    curCol = (i-1) %% plotCols + 1
    print(plots[[i]], vp = vplayout(curRow, curCol ))
  }
  
}
