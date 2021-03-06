App <- setRefClass(
  Class = "PBJApp",
  fields = c("webRoot", "fileRoot", "studyRoot", "staticPaths", "routes",
             "token", "datasetExt", "niftiExt", "study"),
  methods = list(
    initialize = function(.study = NULL) {
      datasetExt <<- "\\.(csv|rds)$"
      niftiExt <<- "\\.nii(\\.gz)?$"
      fileRoot <<- getwd()

      webRoot <<- file.path(find.package("pbjGUI"), "webroot")
      if (!dir.exists(webRoot)) {
        # try to find webroot in the inst directory
        webRoot <<- file.path(find.package("pbjGUI"), "inst", "webroot")

        if (!dir.exists(webRoot)) {
          stop("Can't find package webroot directory!")
        }
      }

      if (!is.null(.study)) {
        study <<- .study
        studyRoot <<- study$outdir
      } else {
        study <<- NULL
        studyRoot <<- tempfile()
        dir.create(studyRoot)
      }

      # setup static paths for httpuv
      staticPaths <<- list(
        "/static"  = httpuv::staticPath(file.path(webRoot, "static"),
                                        indexhtml = TRUE, fallthrough = TRUE)
      )

      # setup routes
      routes <<- list(
        list(method = "GET", path = "^/$", handler = .self$getIndex),
        list(method = "GET", path = "^/saveStudy$", handler = .self$saveStudy),
        list(method = "POST", path = "^/browse$", handler = .self$browse),
        list(method = "POST", path = "^/checkDataset$", handler = .self$checkDataset),
        list(method = "POST", path = "^/createStudy$", handler = .self$createStudy),
        list(method = "GET", path = "^/studyImage/", handler = .self$studyImage),
        list(method = "GET", path = "^/hist$", handler = .self$plotHist),
        list(method = "POST", path = "^/createStatMap$", handler = .self$createStatMap),
        list(method = "GET", path = "^/statMap$", handler = .self$getStatMap),
        list(method = "POST", path = "^/createSEI$", handler = .self$createSEI),
        list(method = "GET", path = "^/sei$", handler = .self$getSEI)
      )

      # generate a random token for this session
      token <<- paste(as.character(openssl::rand_bytes(12)), collapse = "")
    },

    call = function(req) {
      method <- req$REQUEST_METHOD
      path <- req$PATH_INFO
      cat("Method: ", method, " path: ", path, "\n", sep="")
      response <- NULL

      # always check for token
      query <- parseQuery(req)
      if (is.null(query$token) || query$token != token) {
        cat("Bad token\n")
        response <- makeTextResponse('Invalid token', 401L)
        return(response)
      }

      for (route in routes) {
        if (route$method == method && grepl(route$path, path)) {
          cat("Path matched route pattern: ", route$path, "\n", sep="")
          result <- try(route$handler(req, query))
          if (inherits(result, 'try-error')) {
            print(result)
            result <- makeErrorResponse(list(error = as.character(result)))
          }
          response <- result
          break
        }
      }

      if (is.null(response)) {
        # path didn't match (or handler returned NULL), return 404
        cat("Path didn't match or handler returned NULL\n")
        response <- makeTextResponse('Not found', 404L)
      }

      return(response)
    },

    # handler for GET /
    getIndex = function(req, query) {
      # render the main template
      vars <- getTemplateVars()
      studyTemplate <- getTemplate("study.html")
      modelTemplate <- getTemplate("model.html")
      statMapTemplate <- getTemplate("statMap.html")
      seiTemplate <- getTemplate("sei.html")

      mainTemplate <- getTemplate("index.html")
      partials <- list(studyTab = studyTemplate, modelTab = modelTemplate,
                       statMapTab = statMapTemplate, seiTab = seiTemplate)
      body <- whisker::whisker.render(mainTemplate, data = vars,
                                      partials = partials)

      # setup the response
      response <- makeHTMLResponse(body)
      return(response)
    },

    # handler for GET /saveStudy
    saveStudy = function(req, query) {
      if (is.null(study)) {
        response <- makeTextResponse('Study does not exist', 400)
        return(response)
      }

      path <- study$save()
      return(makeAttachmentResponse(path))
    },

    # handler for POST /browse
    browse = function(req, query) {
      result <- parsePost(req)
      if (inherits(result, 'error')) {
        # parsePost returned an error response
        return(result)
      }

      params <- result
      if (is.null(params$path)) {
        path <- getwd()
      } else {
        path <- params$path
      }
      errors <- validatePath(path, dir = TRUE)
      if (!is.null(errors)) {
        response <- makeErrorResponse(list(path = errors))
        return(response)
      }

      ext <- ""
      glob <- ""
      if (!is.null(params$type)) {
        if (params$type == "nifti") {
          ext <- niftiExt
          glob <- "*.nii, *.nii.gz"
        } else if (params$type == "csv") {
          ext <- datasetExt
          glob <- "*.csv, *.rds"
        }
      }

      files <- file.info(list.files(path, full.names = TRUE))
      files$path <- row.names(files)
      files$name <- basename(files$path)
      files <- files[grepl(ext, files$name, ignore.case = TRUE) | files$isdir,]
      files$type <- ifelse(files$isdir, "folder", "file")
      files <- files[order(!files$isdir, files$name),]

      browseTemplate <- getTemplate("browse.html")
      vars <- list(
        path = path,
        parent = normalizePath(file.path(path, '..')),
        files = whisker::rowSplit(files),
        empty = (nrow(files) == 0)
      )
      data <- list(
        html = unbox(whisker::whisker.render(browseTemplate, data = vars)),
        glob = glob
      )

      # setup the response
      response <- makeJSONResponse(data)
      return(response)
    },

    readDataset = function(path) {
      ext <- tolower(tools::file_ext(path))
      if (ext == "csv") {
        read.csv(path)
      } else if (ext == "rds") {
        readRDS(path)
      } else {
        stop("unsupported file extension")
      }
    },

    # handler for POST /checkDataset
    checkDataset = function(req, query) {
      result <- parsePost(req)
      if (inherits(result, 'error')) {
        # parsePost returned an error response
        return(result)
      }

      params <- result
      errors <- list()
      errors$path <- validatePath(params$path, dir = FALSE, pattern = datasetExt)
      if (is.null(errors$path)) {
        # no errors so far
        path <- normalizePath(params$path, mustWork = TRUE)
        dataset <- try(readDataset(path))
        if (inherits(dataset, "try-error")) {
          errors$path <- "is not a valid dataset file"
        }

        if (!inherits(dataset, "try-error")) {
          # try to guess what columns contain image path information
          columns <- which(apply(dataset, MARGIN = 2,
                                 FUN = function(col) any(grepl(niftiExt, col, ignore.case = TRUE))))
          if (length(columns) == 0) {
            errors$path <- "does not contain file paths to NIFTI images"
          } else {
            columns <- names(dataset)[columns]
          }
        }
      }

      if (length(errors) > 0) {
        return(makeErrorResponse(errors))
      }

      template <- getTemplate("checkDataset.html")
      vars <- list(
        path = path,
        columns = lapply(columns, function(name) {
          list(name = name, values = dataset[[name]])
        })
      )
      html <- whisker::whisker.render(template, data = vars)

      # setup the response
      response <- makeHTMLResponse(html)
      return(response)
    },

    createStudy = function(req, query) {
      result <- parsePost(req)
      if (inherits(result, 'error')) {
        # parsePost returned an error response
        return(result)
      }

      params <- result
      errors <- list()
      errors$dataset <- validatePath(params$dataset, dir = FALSE, pattern = datasetExt)
      errors$mask <- validatePath(params$mask, dir = FALSE, pattern = niftiExt)
      errors$template <- validatePath(params$template, dir = FALSE, pattern = niftiExt)

      if (is.null(errors$dataset)) {
        datasetPath <- normalizePath(params$dataset, mustWork = TRUE)
        dataset <- try(readDataset(datasetPath))
        if (inherits(dataset, "try-error")) {
          errors$path <- "is not a valid dataset file"
        } else {
          # check outcome column
          if (is.null(params$outcomeColumn) || !nzchar(params$outcomeColumn)) {
            errors$outcomeColumn <- 'is required'
          } else if (!(params$outcomeColumn %in% names(dataset))) {
            errors$outcomeColumn <- 'is not present in dataset'
          } else {
            # check for valid filenames
            info <- file.info(dataset[[params$outcomeColumn]])
            bad <- subset(info, is.na(size))
            if (nrow(bad) > 0) {
              errors$outcomeColumn <- paste0("contains missing files: ",
                                             paste(row.names(bad), collapse = ", "))
            }
          }
        }
      }

      if (length(errors) > 0) {
        return(makeErrorResponse(errors))
      }

      # create study object
      images <- normalizePath(dataset[[params$outcomeColumn]], mustWork = TRUE)
      mask <- normalizePath(params$mask, mustWork = TRUE)
      template <- normalizePath(params$template, mustWork = TRUE)
      study <<- PBJStudy$new(images = images,
                             form = ~ 1,
                             formred = NULL,
                             mask = mask,
                             data = dataset,
                             template = template,
                             .outdir = studyRoot,
                             datasetPath = datasetPath)

      vars <- getTemplateVars()
      studyTemplate <- getTemplate("study.html")
      studyHTML <- whisker::whisker.render(studyTemplate, data = vars)

      modelTemplate <- getTemplate("model.html")
      modelHTML <- whisker::whisker.render(modelTemplate, data = vars)

      data <- list(study = unbox(studyHTML), model = unbox(modelHTML))
      response <- makeJSONResponse(data)
      return(response)
    },

    # handler for GET /studyImage
    studyImage = function(req, query) {
      # parse path
      path <- req$PATH_INFO
      parts <- strsplit(path, "/")[[1]][c(-1, -2)]

      filename <- NULL
      candidate <- NULL
      ext <- NULL
      if (parts[1] == "outcome") {
        type <- parts[1]
        md <- regexpr("^([0-9]+)(\\.nii(\\.gz)?)$", parts[2], ignore.case = TRUE, perl = TRUE)
        if (md >= 0) {
          # R's regex support is terrible
          index <- as.integer(substr(parts[2], attr(md, 'capture.start')[1], attr(md, 'capture.start')[1] + attr(md, 'capture.length')[1] - 1))
          ext <- substr(parts[2], attr(md, 'capture.start')[2], attr(md, 'capture.start')[2] + attr(md, 'capture.length')[2] - 1)

          # find candidate file
          if (index >= 1 && index <= length(study$images)) {
            candidate <- study$images[index]
          }
        }
      } else if (parts[1] == "sei") {
        if (study$hasSEI()) {
          cftName <- parts[2]
          imageName <- parts[3]
          if (cftName %in% names(study$sei)) {
            cft <- study$sei[[cftName]]
            md <- regexpr("^(clustermap|pmap)(\\.nii(\\.gz)?)$", imageName, ignore.case = TRUE, perl = TRUE)
            if (md >= 0) {
              type <- substr(imageName, attr(md, 'capture.start')[1], attr(md, 'capture.start')[1] + attr(md, 'capture.length')[1] - 1)
              ext <- substr(imageName, attr(md, 'capture.start')[2], attr(md, 'capture.start')[2] + attr(md, 'capture.length')[2] - 1)

              # find candidate file
              if (type == "clustermap") {
                candidate <- study$sei[[cftName]]$clustermapfile
              } else if (type == "pmap") {
                candidate <- study$sei[[cftName]]$pmapfile
              }
            }
          }
        }
      } else {
        md <- regexpr("^(template|mask|statMapStat|statMapCoef)(\\.nii(\\.gz)?)$", parts[1], ignore.case = TRUE, perl = TRUE)
        if (md >= 0) {
          type <- substr(parts[1], attr(md, 'capture.start')[1], attr(md, 'capture.start')[1] + attr(md, 'capture.length')[1] - 1)
          ext <- substr(parts[1], attr(md, 'capture.start')[2], attr(md, 'capture.start')[2] + attr(md, 'capture.length')[2] - 1)

          if (type == "template") {
            candidate <- study$template
          } else if (type == "mask") {
            candidate <- study$mask
          } else if (type == "statMapStat" && !is.null(study$statMap)) {
            candidate <- study$statMap$stat
          } else if (type == "statMapCoef" && !is.null(study$statMap)) {
            candidate <- study$statMap$coef
          }
        }
      }

      # make sure file extension matches
      if (!is.null(candidate) && !is.null(ext)) {
        ext <- paste0(ext, '$')
        if (grepl(ext, candidate, ignore.case = TRUE)) {
          filename <- candidate
        }
      }

      if (!is.null(filename)) {
        return(makeFileResponse(filename))
      } else {
        return(makeTextResponse("Not found", 404L))
      }
    },

    # handler for GET /hist
    plotHist = function(req, query) {
      errors <- list()
      params <- query
      if (!("var" %in% names(params))) {
        # missing var name
        errors$var <- 'is required'
      } else if (!study$isVarNumeric(params$var)) {
        # invalid var name
        errors$var <- 'is invalid'
      }
      if (length(errors) > 0) {
        return(makeErrorResponse(errors))
      }

      # plot histogram to PNG
      filename <- tempfile(fileext = "png")
      png(filename)
      study$plotHist(params$var)
      dev.off()

      # setup the response
      response <- makeImageResponse(filename)
      return(response)
    },

    # handler for POST /createStatMap
    createStatMap = function(req, query) {
      result <- parsePost(req)
      if (inherits(result, 'error')) {
        # parsePost returned an error response
        return(result)
      }

      # validate params
      errors <- list()
      params <- result
      if (!("formfull" %in% names(params))) {
        # missing full formula
        errors$formfull <- 'is required'
      } else {
        formfull <- try(as.formula(params$formfull))
        if (inherits(formfull, 'try-error')) {
          errors$formfull <- 'is invalid'
        }
      }

      formred <- NULL
      if ("formred" %in% names(params)) {
        if (!is.character(params$formred)) {
          errors$formred <- 'must be a string'
        } else if (nzchar(params$formred)) {
          formred <- try(as.formula(params$formred))
          if (inherits(formred, 'try-error')) {
            errors$formred <- 'is not a valid formula'
          }
        }
      } else {
        formred <- NULL
      }

      weightsColumn <- NULL
      if ("weightsColumn" %in% names(params)) {
        if (!is.character(params$weightsColumn)) {
          errors$weightsColumn <- 'must be a string'
        } else if (nzchar(params$weightsColumn)) {
          if (!(params$weightsColumn %in% names(study$data))) {
            errors$weightsColumn <- 'is not a valid column name'
          } else {
            weightsColumn <- params$weightsColumn
          }
        }
      }

      invertedWeights <- FALSE
      if ("invertedWeights" %in% names(params)) {
        if (isTRUE(params$invertedWeights)) {
          invertedWeights <- TRUE
        } else if (isFALSE(params$invertedWeights)) {
          invertedWeights <- FALSE
        } else {
          errors$invertedWeights <- 'must be either true or false'
        }
      }

      robust <- TRUE
      if ("robust" %in% names(params)) {
        if (isTRUE(params$robust)) {
          robust <- TRUE
        } else if (isFALSE(params$robust)) {
          robust <- FALSE
        } else {
          errors$robust <- 'must be either true or false'
        }
      }

      transform <- "none"
      if ("transform" %in% names(params)) {
        if (params$transform == "none") {
          transform <- "none"
        } else if (params$transform == "t") {
          transform <- "t"
        } else if (params$transform == "edgeworth") {
          transform <- "edgeworth"
        } else {
          errors$transform <- 'must be "none", "t", or "edgeworth"'
        }
      }

      zeros <- FALSE
      if ("zeros" %in% names(params)) {
        if (isTRUE(params$zeros)) {
          zeros <- TRUE
        } else if (isFALSE(params$zeros)) {
          zeros <- FALSE
        } else {
          errors$zeros <- 'must be either true or false'
        }
      }

      HC3 <- FALSE
      if ("HC3" %in% names(params)) {
        if (isTRUE(params$HC3)) {
          HC3 <- TRUE
        } else if (isFALSE(params$HC3)) {
          HC3 <- FALSE
        } else {
          errors$HC3 <- 'must be either true or false'
        }
      }

      if (length(errors) > 0) {
        return(makeErrorResponse(errors))
      }

      study$form <<- formfull
      study$formred <<- formred
      study$weightsColumn <<- weightsColumn
      study$invertedWeights <<- invertedWeights
      study$robust <<- robust
      study$transform <<- transform
      study$zeros <<- zeros
      study$HC3 <<- HC3

      result <- try(study$startStatMapJob())
      if (inherits(result, 'try-error')) {
        return(makeErrorResponse(list(error = unbox(as.character(result)))))
      }

      response <- makeJSONResponse(list(running = unbox(TRUE)))
      return(response)
    },

    # handler for GET /statMap
    getStatMap = function(req, query) {
      data <- list()
      status <- 200L

      if (study$hasStatMapJob()) {
        # job is running or just finished
        data$log <- unbox(study$readStatMapJobLog())

        if (study$isStatMapJobRunning()) {
          # job is still running
          data$status <- unbox("running")
        } else {
          # job finished successfully or failed
          result <- study$finalizeStatMapJob()
          if (inherits(result, "try-error")) {
            data$status <- unbox("failed")
            status <- 500L
          } else {
            data$status <- unbox("finished")
          }
        }
      }

      if (study$hasStatMap()) {
        # statMap exists, render template
        statMapTemplate <- getTemplate("statMap.html")
        vars <- getTemplateVars()
        data$html <- unbox(whisker::whisker.render(statMapTemplate, data = vars))

        if (is.null(data$status)) {
          data$status <- unbox("finished")
        }
      }

      if (length(data) == 0) {
        response <- makeTextResponse('Not found', 404L)
      } else {
        response <- makeJSONResponse(data, status)
      }
      return(response)
    },

    # handler for POST /createSEI
    createSEI = function(req, query) {
      result <- parsePost(req)
      if (inherits(result, 'error')) {
        # parsePost returned an error response
        return(result)
      }

      # validate params
      errors <- list()
      params <- result
      cftType <- "s"
      if (!("cftType" %in% names(params))) {
        # missing CFT type
        errors$cftType <- 'is required'
      } else if (!(params$cftType %in% c("s", "p"))) {
        errors$cftType <- 'must be "s" or "p"'
      } else {
        cftType <- params$cftType
      }

      cfts <- NULL
      if (!("cfts" %in% names(params))) {
        errors$cfts <- 'is required'
      } else if (!is.list(params$cfts)) {
        errors$cfts <- 'must be a list'
      } else if (length(params$cfts) == 0) {
        errors$cfts <- 'must have at least 1 value'
      } else {
        for (i in 1:length(params$cfts)) {
          value <- as.numeric(params$cfts[[i]])
          if (is.na(value)) {
            errors$cfts <- 'has invalid values'
            break
          }
          if (value < 0.00001) {
            errors$cfts <- 'has values that are too small'
            break
          }
          if (value > 0.99999) {
            errors$cfts <- 'has values that are too large'
            break
          }
        }
        if (is.null(errors$cfts)) {
          cfts <- as.numeric(params$cfts)
        }
      }

      method <- NULL
      if (!("method" %in% names(params))) {
        errors$method <- 'is required'
      } else if (!(params$method %in% c('t', 'permutation', 'conditional', 'nonparametric'))) {
        errors$method <- 'is invalid'
      } else {
        method <- params$method
      }

      nboot <- NULL
      if (!("nboot" %in% names(params))) {
        errors$nboot <- 'is required'
      } else {
        nboot <- as.integer(params$nboot)
        if (is.na(nboot)) {
          errors$nboot <- 'is invalid'
        } else if (nboot < 1) {
          errors$nboot <- 'is too small'
        }
      }

      if (length(errors) > 0) {
        return(makeErrorResponse(errors))
      }

      study$cftType <<- cftType
      study$cfts <<- cfts
      study$method <<- method
      study$nboot <<- nboot

      result <- try(study$startSEIJob())
      if (inherits(result, 'try-error')) {
        print(result)
        return(makeErrorResponse(list(error = as.character(result))))
      }

      response <- makeJSONResponse(list(running = unbox(TRUE)))
      return(response)
    },

    # handler for GET /sei
    getSEI = function(req, query) {
      data <- list()
      status <- 200L

      if (study$hasSEIJob()) {
        # job is running or just finished
        data$progress <- study$getSEIJobProgress()

        if (study$isSEIJobRunning()) {
          # job is still running
          data$status <- "running"
        } else {
          # job finished successfully or failed
          result <- study$finalizeSEIJob()
          if (inherits(result, "try-error")) {
            data$status <- "failed"
            status <- 500L
          } else {
            data$status <- "finished"
          }
        }
      }

      if (study$hasSEI()) {
        seiTemplate <- getTemplate("sei.html")
        vars <- getTemplateVars()
        data$html <- whisker::whisker.render(seiTemplate, data = vars)

        if (is.null(data$status)) {
          data$status <- "finished"
        }
      }

      if (length(data) == 0) {
        response <- makeTextResponse('Not found', 404L)
      } else {
        response <- makeJSONResponse(data, status, unbox = TRUE)
      }
      return(response)
    },

    getTemplate = function(templateName) {
      templateFile <- file.path(webRoot, "templates", templateName)
      template <- readChar(templateFile, file.info(templateFile)$size)
      return(template)
    },

    getTemplateVars = function() {
      result <- list(
        token = token,
        fileRoot = fileRoot,
        hasStatMap = (!is.null(study) && study$hasStatMap()),
        hasSEI = (!is.null(study) && study$hasSEI())
      )

      if (!is.null(study)) {
        result$study <- list(
          datasetPath = study$datasetPath,
          form = paste(as.character(study$form), collapse = " "),
          formred = paste(as.character(study$formred), collapse = " "),
          invertedWeights = study$invertedWeights,
          robust = study$robust,
          transformOptions = study$getTransformOptions(),
          zeros = study$zeros,
          HC3 = study$HC3,
          varInfo = study$getVarInfo(),
          cftTypeOptions = study$getCftTypeOptions(),
          cftValues = study$getCftValues(),
          nboot = study$nboot,
          hasStatMap = study$hasStatMap(),
          hasSEI = study$hasSEI(),
          methodOptions = study$getMethodOptions()
        )

        # get file extension for template image
        hasTemplate <- !is.null(study$template)
        if (hasTemplate) {
          md <- regexpr(niftiExt, study$template)
          templateExt <- substr(study$template, md, md + attr(md, 'match.length') - 1)
        } else {
          templateExt <- NULL
        }

        # create list of data rows for visualization template
        result$study$dataRows <- lapply(1:length(study$images), function(i) {
          # get file extension for outcome image
          md <- regexpr(niftiExt, study$images[i])
          outcomeExt <- substr(study$images[i], md, md + attr(md, 'match.length') - 1)

          list(index = i, selected = (i == 1), hasTemplate = hasTemplate,
               templateExt = templateExt,
               outcomeBase = basename(study$images[i]),
               outcomeExt = outcomeExt)
        })

        statMap <- NULL
        if (study$hasStatMap()) {
          # get file extension for statMap image
          md <- regexpr(niftiExt, study$statMap$stat)
          statExt <- substr(study$statMap$stat, md, md + attr(md, 'match.length') - 1)

          md <- regexpr(niftiExt, study$statMap$coef)
          coefExt <- substr(study$statMap$coef, md, md + attr(md, 'match.length') - 1)

          statMap <- list(
            hasTemplate = hasTemplate, templateExt = templateExt,
            statExt = statExt, coefExt = coefExt
          )
        }
        result$study$statMap <- statMap

        sei <- NULL
        if (study$hasSEI()) {
          cfts <- lapply(5:length(study$sei), function(i) {
            list(
              index = i,
              selected = (i == 5),
              name = names(study$sei)[i],
              sname = gsub("\\W", "_", names(study$sei)[i]),
              boots = study$sei[[i]]$boots,
              clusters = lapply(names(study$sei[[i]]$obs), function(n) {
                list(
                  name = n,
                  size = unname(study$sei[[i]]$obs[n]),
                  pvalue = unname(study$sei[[i]]$pvalues[n])
                )
              })
            )
          })
          sei <- list(
            hasTemplate = hasTemplate,
            templateExt = templateExt,
            cfts = cfts
          )
        }
        result$study$sei <- sei
      }

      return(result)
    },

    makeHTMLResponse = function(body, status = 200L) {
      response <- list(
        status = status, headers = list("Content-Type" = "text/html"),
        body = body
      )
      return(response)
    },

    makeTextResponse = function(body, status = 200L) {
      response <- list(
        status = status, headers = list("Content-Type" = "text/plain"),
        body = body
      )
      return(response)
    },

    makeErrorResponse = function(errors, status = 400L) {
      response <- list(
        status = status, headers = list("Content-Type" = "application/json"),
        body = jsonlite::toJSON(errors)
      )
      class(response) <- c('error')
      return(response)
    },

    makeImageResponse = function(filename, type = "png", status = 200L) {
      contentType <- paste0("image/", type)
      return(makeFileResponse(filename, contentType, status))
    },

    makeAttachmentResponse = function(filename, status = 200L) {
      cd <- paste0('attachment; filename="', basename(filename), '"')
      return(makeFileResponse(filename, status = status, contentDisposition = cd))
    },

    makeFileResponse = function(filename, contentType = "application/octet-stream", status = 200L, contentDisposition = "inline") {
      response <- list(
        status = status,
        headers = list(
          "Content-Type" = contentType,
          "Content-Disposition" = contentDisposition
        ),
        body = c(file = filename)
      )
      return(response)
    },

    makeJSONResponse = function(data, status = 200L, unbox = FALSE) {
      response <- list(
        status = status, headers = list("Content-Type" = "application/json"),
        body = jsonlite::toJSON(data, auto_unbox = unbox)
      )
      return(response)
    },

    parsePost = function(req) {
      # parse request data as JSON
      result <- try({
        jsonlite::fromJSON(rawToChar(req$rook.input$read()), simplifyVector = FALSE)
      }, silent = TRUE)

      if (inherits(result, "try-error")) {
        print(result)
        response <- makeErrorResponse(list(error = "invalid JSON"))
        return(response)
      }

      return(result)
    },

    parseQuery = function(req) {
      result <- list()

      # parse query in URI
      query <- httpuv::decodeURIComponent(req$QUERY_STRING)
      if (substr(query, 1, 1) != "?") {
        # invalid/empty query string
        return(result)
      }
      query <- substring(query, 2)

      parts <- strsplit(query, "&", fixed = TRUE)[[1]]
      parts <- strsplit(parts, "=", fixed = TRUE)
      for (part in parts) {
        name <- part[1]
        value <- part[2]
        result[[name]] <- value
      }

      return(result)
    },

    validatePath = function(path, dir = FALSE, pattern = NULL) {
      errors <- NULL
      if (is.null(path)) {
        errors <- "is required"
      } else if (!is.character(path)) {
        errors <- "must be a character vector"
      } else if (length(path) != 1) {
        errors <- "must have only 1 value"
      } else if (!nzchar(path)) {
        errors <- "must not be empty"
      } else if (!file.exists(path)) {
        errors <- "does not exist"
      } else if (file.info(path)$isdir != dir) {
        if (dir) {
          errors <- "must be a directory"
        } else {
          errors <- "must be a regular file"
        }
      } else if (!is.null(pattern) && !grepl(pattern, path, ignore.case = TRUE)) {
        errors <- paste0("must match pattern: ", pattern)
      } else {
        result <- try(normalizePath(path, mustWork = TRUE))
        if (inherits(result, 'try-error')) {
          errors <- "is invalid"
        }
      }
      return(errors)
    }
  )
)
