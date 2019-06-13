## atakrig
## Function: area-to-point/area Kriging
## Author: Maogui Hu, 2019.02.28.

# require(sp)
# require(gstat)
# require(FNN)


## ataKriging: Area-to-area ordinary Kriging ----
# Input:
#   x: discretized area, list(areaValues, discretePoints):
#       areaValues: sample values, data.frame(areaId,centx,centy,value).
#       discretePoints: discretized area-samples, data.frame(areaId,ptx,pty,weight), weight is normalized.
#   unknown: discreteArea object or data.frame(areaId,ptx,pty,weight) discretized destination areas, weight is normalized.
#   ptVgm: point scale variogram, ataKrigVgm.
#   nmax: max number of neighborhoods used for interpolation.
#	  longlat: coordinates are longitude/latitude or not.
#   showProgress: show progress bar for batch interpolation (multi destination areas).
#   nopar: for internal use. Disable parallel process in the function even if ataEnableCluster() has been called.
# Output: estimated value of destination area and its variance
ataKriging <- function(x, unknown, ptVgm, nmax=10, longlat=FALSE, showProgress=TRUE, nopar=FALSE) {
  stopifnot(nmax > 0)
  if(nmax < Inf) { # local neigbourhood kriging.
    return(.ataKriging.local(x, unknown, ptVgm, nmax, longlat, showProgress, nopar))
  }

  if(is(unknown, "discreteArea")) unknown <- unknown$discretePoints
  if(is(ptVgm, "ataKrigVgm")) ptVgm <- extractPointVgm(ptVgm)

  sampleIds <- x$areaValues[,1]
  nSamples <- length(sampleIds)		# number of samples

  ## kriging system: C * wmu = D
  # C matrix
  C <- matrix(1, nrow=nSamples+1, ncol=nSamples+1)
  for(i in 1:nSamples) {
    sampleI <- x$discretePoints[x$discretePoints[,1] == sampleIds[i],]
    for(j in i:nSamples) {
      sampleJ <- x$discretePoints[x$discretePoints[,1] == sampleIds[j],]
      C[i,j] <- .ataCov(sampleI[,2:4], sampleJ[,2:4], ptVgm, longlat = longlat)
      C[j,i] <- C[i,j]
    }
  }
  C[nSamples+1,nSamples+1] <- 0

  unknownAreaIds <- sort(unique(unknown[,1]))

  krigOnce <- function(k) {
    cur <- unknown[unknown[,1] == unknownAreaIds[k], 2:4, drop=F]

    # D matrix
    D <- matrix(1, nrow=nSamples+1, ncol=1)
    for(i in 1:nSamples) {
      sampleI <- x$discretePoints[x$discretePoints[,1] == sampleIds[i],]
      D[i] <- .ataCov(sampleI[,2:4,drop=F], cur, ptVgm, longlat = longlat)
    }

    # solving
    solvedByGInv <- FALSE
    wmu <- try(solve(C, D), T)
    if(class(wmu) == "try-error") {
      wmu <- MASS::ginv(C) %*% D
      solvedByGInv <- TRUE
    }
    w <- wmu[1:nSamples]
    mu <- wmu[(nSamples+1):nrow(wmu)]

    # estimation
    yest <- sum(w*x$areaValues[,4])
    yvar <- .ataCov(cur, cur, ptVgm, longlat = longlat) - sum(wmu * D)

    return(data.frame(areaId=unknownAreaIds[k], pred=yest, var=yvar))
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=length(unknownAreaIds), width = 50, style = 3)

  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:length(unknownAreaIds)) {
      estResults <- rbind(estResults, krigOnce(k))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
    estResults <-
      foreach(k = 1:length(unknownAreaIds), .combine = rbind, .options.snow=list(progress=progress),
              .export = c(".ataCov",".calcAreaCentroid"),
              .packages = c("sp","gstat")) %dopar% {
                krigOnce(k)
              }
    clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
  }

  if(showProgress) close(pb)

  unknownCenter <- .calcAreaCentroid(unknown)
  estResults <- merge(unknownCenter, estResults)

  return(estResults)
}


## ataKriging.cv: ataKriging cross-validation ----
#   nfold: integer; n-fold cross validation.
ataKriging.cv <- function(x, nfold=10, ptVgm, nmax=10, longlat=FALSE, showProgress=TRUE, nopar=FALSE) {
  N <- nrow(x$areaValues)
  if(missing(nfold)) {
    nfold <- N
  }

  if(length(nfold) == 1) {
    if(nfold <= 1 || nfold > N) {
      nfold <- N
    }

    if(nfold == N) {
      # leave-one-out
      indexM <- matrix(sort(x$areaValues[,1]), ncol = 1)
    } else {
      # n fold
      rndIds <- sample(x$areaValues[,1], N)
      nsize <- ceiling(N/nfold)
      indexM <- matrix(NA, nrow=nfold, ncol=nsize)
      nfrom <- nto <- 0
      for (i in 1:nfold) {
        nfrom <- nto + 1
        nto <- min(nsize * i, N)
        indexM[i,1:(nto-nfrom+1)] <- sort(rndIds[nfrom:nto])
      }
    }
  } else {
    indexM <- matrix(nfold, nrow = 1)
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=nrow(indexM), width = 50, style = 3)


  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:nrow(indexM)) {
      xknown <- subsetDiscreteArea(x, indexM[k,], revSel = TRUE)
      unknown <- subsetDiscreteArea(x, indexM[k,])$discretePoints
      estResults <- rbind(estResults, ataKriging(xknown, unknown, ptVgm, nmax, longlat, showProgress = FALSE, nopar = TRUE))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    bInnerParallel <- ncol(indexM) > 2*nrow(indexM)
    if(bInnerParallel) {
      estResults <- c()
      for (k in 1:nrow(indexM)) {
        xknown <- subsetDiscreteArea(x, indexM[k,], revSel = TRUE)
        unknown <- subsetDiscreteArea(x, indexM[k,])$discretePoints
        estResults <- rbind(estResults, ataKriging(xknown, unknown, ptVgm, nmax, longlat, showProgress = FALSE, nopar = FALSE))
        if(showProgress) setTxtProgressBar(pb, k)
      }
    } else {
      progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
      estResults <-
        foreach(k = 1:nrow(indexM), .combine = rbind, .options.snow=list(progress=progress),
                .export = c("subsetDiscreteArea",".ataCov",".calcAreaCentroid","ataKriging",".ataKriging.local"),
                .packages = c("sp","gstat","FNN")) %dopar% {
                  xknown <- subsetDiscreteArea(x, indexM[k,], revSel = TRUE)
                  unknown <- subsetDiscreteArea(x, indexM[k,])$discretePoints
                  ataKriging(xknown, unknown, ptVgm, nmax, longlat, showProgress = FALSE, nopar = TRUE)
                }
      clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
    }
  }
  if(showProgress) close(pb)

  estResults <- estResults[order(estResults$areaId),]
  indx <- match(estResults[,1], x$areaValues[,1])
  # estResults$diff <- x$areaValues[indx,4] - estResults[,4]
  estResults$value <- x$areaValues[indx,4]

  return(estResults)
}


## .ataKriging.local: [internal use only]. ----
.ataKriging.local <- function(x, unknown, ptVgm, nmax=10, longlat=FALSE, showProgress=TRUE, nopar=FALSE) {
  if(is(unknown, "discreteArea")) unknown <- unknown$discretePoints

  unknown <- unknown[sort.int(unknown[,1], index.return = T)$ix,]
  unknownCenter <- .calcAreaCentroid(unknown)

  nb <- get.knnx(as.matrix(x$areaValues[,2:3,drop=F]), as.matrix(unknownCenter[,2:3,drop=F]), nmax)
  nb$nn.index <- matrix(x$areaValues[nb$nn.index,1], ncol = ncol(nb$nn.index))

  unknownAreaIds <- unknownCenter[,1]

  krigOnce <- function(k) {
    curUnknown <- unknown[unknown[,1] == unknownAreaIds[k],]
    curAreaPts <- x$discretePoints[x$discretePoints[,1] %in% nb$nn.index[k,],]
    curAreaVals <- x$areaValues[x$areaValues[,1] %in% nb$nn.index[k,],]

    estResult <- ataKriging(x=list(discretePoints=curAreaPts, areaValues = curAreaVals),
                            curUnknown, ptVgm, nmax=Inf, longlat=longlat, showProgress=FALSE, nopar=TRUE)
    return(estResult)
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=length(unknownAreaIds), width = 50, style = 3)

  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:length(unknownAreaIds)) {
      estResults <- rbind(estResults, krigOnce(k))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
    estResults <-
      foreach(k = 1:length(unknownAreaIds), .combine = rbind, .options.snow=list(progress=progress),
              .export = c("ataKriging",".ataCov",".calcAreaCentroid"),
              .packages = c("sp","gstat")) %dopar% {
                krigOnce(k)
              }
    clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
  }
  if(showProgress) close(pb)

  return(estResults)
}


## ataCoKriging: Area-to-area ordinary CoKriging ----
# Input:
#   x: discretized areas, list(
#      `varId1`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)),
#      `varId2`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)),
#       ...,
#      `varIdn`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)))
#   unknown: discretized destination area, data.frame(areaId,ptx,pty,weight).
#   ptVgms: point scale direct or cross variograms, ataKrigVgm.
#   nmax: max number of neighborhoods used for interpolation.
#	  longlat: coordinates are longitude/latitude or not.
#   oneCondition: oneCondition cokriging, assuming expected means of variables known and constant with the study area.
#   meanVal: expected means of variables for oneCondition cokriging, data.frame(varId,value). If missing, simple mean values of
#      areas from x will be used instead.
#   auxRatioAdj: for oneCondition kriging, adjusting the auxiliary variable residue by a ratio between the primary variable mean
#      and auxiliary variable mean.
#   showProgress: show progress bar for batch interpolation (multi destination areas).
#   nopar: disable parallel process in the function even if ataEnableCluster() has been called, mainly for  internal use.
# Output: estimated value of destination area and its variance
ataCoKriging <- function(x, unknownVar, unknown, ptVgms, nmax=10, longlat=FALSE, oneCondition=FALSE,
                         meanVal=NULL, auxRatioAdj=TRUE, showProgress=TRUE, nopar=FALSE) {
  stopifnot(nmax > 0)
  if(nmax < Inf) {
    return(.ataCoKriging.local(x, unknownVar, unknown, ptVgms, nmax, longlat, oneCondition, meanVal, auxRatioAdj, showProgress, nopar))
  }

  if(is(unknown, "discreteArea")) unknown <- unknown$discretePoints
  if(is(ptVgms, "ataKrigVgm")) ptVgms <- extractPointVgm(ptVgms)

  # sort areaId in ascending order.
  for (i in 1:length(x)) {
    x[[i]]$areaValues <- x[[i]]$areaValues[sort.int(x[[i]]$areaValues[,1], index.return = T)$ix,]
  }

  # combine all data together.
  varIds <- sort(names(x))
  xAll <- list(areaValues=NULL, discretePoints=NULL)
  for (id in varIds) {
    if(!hasName(x[[id]], "discretePoints")) {
      x[[id]]$discretePoints <- cbind(x[[id]]$areaValues[,1:3], data.frame(weight=rep(1,nrow(x[[id]]$areaValues))))
      names(x[[id]]$discretePoints)[2:3] <- c("ptx","pty")
    }

    x[[id]]$areaValues$varId <- id
    x[[id]]$areaValues$var_areaId <- paste(id, x[[id]]$areaValues[,1], sep = "_")
    x[[id]]$discretePoints$varId <- id
    x[[id]]$discretePoints$var_areaId <- paste(id, x[[id]]$discretePoints[,1], sep = "_")

    xAll$areaValues <- rbind(xAll$areaValues, x[[id]]$areaValues)
    xAll$discretePoints <- rbind(xAll$discretePoints, x[[id]]$discretePoints)
  }

  sampleIds <- sort(unique(xAll$discretePoints$var_areaId))
  nSamples <- length(sampleIds)		# number of all samples
  nVars <- length(x) # number of variables

  ## kriging system: C * wmu = D
  if(oneCondition) {
    C <- matrix(0, nrow=nSamples+1, ncol=nSamples+1)
    D <- matrix(0, nrow=nSamples+1, ncol=1)
  } else {
    C <- matrix(0, nrow=nSamples+nVars, ncol=nSamples+nVars)
    D <- matrix(0, nrow=nSamples+nVars, ncol=1)
  }

  # C matrix
  for(i in 1:nSamples) {
    sampleI <- xAll$discretePoints[xAll$discretePoints$var_areaId == sampleIds[i],]
    for(j in i:nSamples) {
      sampleJ <- xAll$discretePoints[xAll$discretePoints$var_areaId == sampleIds[j],]
      ptVgm <- ptVgms[[.crossName(sampleI$varId[1], sampleJ$varId[1])]]
      C[i,j] <- .ataCov(sampleI[,2:4], sampleJ[,2:4], ptVgm, longlat = longlat)
      C[j,i] <- C[i,j]
    }
  }

  if(oneCondition) {
    C[nSamples+1, ] <- 1
    C[, nSamples+1] <- 1
    C[nSamples+1, nSamples+1] <- 0
    D[nSamples+1] <- 1
  } else {
    for (i in 1:nVars) {
      indx <- xAll$areaValues$varId == varIds[i]
      C[nSamples+i, (1:nSamples)[indx]] <- 1
      C[(1:nSamples)[indx], nSamples+i] <- 1
    }
    D[nSamples + which(unknownVar == varIds)] <- 1
  }

  unknownAreaIds <- sort(unique(unknown[,1]))

  krigOnce <- function(k) {
    curUnknown <- unknown[unknown[,1] == unknownAreaIds[k], 2:4]

    # D matrix
    for(i in 1:nSamples) {
      sampleI <- xAll$discretePoints[xAll$discretePoints$var_areaId == sampleIds[i],]
      ptVgm <- ptVgms[[.crossName(sampleI$varId[1], unknownVar)]]
      D[i] <- .ataCov(sampleI[,2:4], curUnknown, ptVgm, longlat = longlat)
    }

    # solving
    solvedByGInv <- FALSE
    wmu <- try(solve(C, D), T)
    if(class(wmu) == "try-error") {
      wmu <- MASS::ginv(C) %*% D
      solvedByGInv <- TRUE
    }

    # estimation
    if(oneCondition) {
      if(is.null(meanVal)) {
        for (id in varIds) {
          meanVal <- rbind(meanVal, data.frame(varId=id, value=mean(x[[id]]$areaValues[,4])))
        }
      }
      rownames(meanVal) <- meanVal$varId

      w <- wmu[1:nSamples]
      w1 <- w[unknownVar == xAll$areaValues$varId]
      yest <- sum(w1 * x[[unknownVar]]$areaValues[,4])
      for (id in varIds[varIds != unknownVar]) {
        w2 <- w[id == xAll$areaValues$varId]
        if (auxRatioAdj && abs(meanVal[id,2]) > 1e-6) {
          yest <- yest + sum(w2 * ((x[[id]]$areaValues[,4] - meanVal[id, 2])*(meanVal[unknownVar, 2]/meanVal[id,2]) + meanVal[unknownVar, 2]))
        } else {
          yest <- yest + sum(w2 * (x[[id]]$areaValues[,4] - meanVal[id, 2] + meanVal[unknownVar, 2]))
        }
      }
    } else {
      w <- wmu[1:nSamples][unknownVar == xAll$areaValues$varId]
      yest <- sum(w * x[[unknownVar]]$areaValues[,4])
    }
    yvar <- .ataCov(curUnknown, curUnknown, ptVgms[[unknownVar]], longlat = longlat) - sum(wmu * D)

    return(data.frame(areaId=unknownAreaIds[k], pred=yest, var=yvar))
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=length(unknownAreaIds), width = 50, style = 3)

  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:length(unknownAreaIds)) {
      estResults <- rbind(estResults, krigOnce(k))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
    estResults <-
      foreach(k = 1:length(unknownAreaIds), .combine = rbind, .options.snow=list(progress=progress),
              .export = c("D","meanVal",".crossName",".ataCov",".calcAreaCentroid"),
              .packages = c("sp","gstat")) %dopar% {
                krigOnce(k)
              }
    clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
  }

  if(showProgress) close(pb)

  unknownCenter <- .calcAreaCentroid(unknown)
  estResults <- merge(unknownCenter, estResults)

  return(estResults)
}


## ataCoKriging.cv: ataCoKriging cross validation. ----
#   nfold: integer; n-fold cross validation.
ataCoKriging.cv <- function(x, unknownVar, nfold=10, ptVgms, nmax=10, longlat=FALSE, oneCondition=FALSE,
                            meanVal=NULL, auxRatioAdj=TRUE, showProgress=TRUE, nopar=FALSE) {
  N <- nrow(x[[unknownVar]]$areaValues)
  if(missing(nfold)) {
    nfold <- N
  }

  if(length(nfold) == 1) {
    if(nfold <= 1 || nfold > N) {
      nfold <- N
    }

    if(nfold == N) {
      # leave-one-out
      indexM <- matrix(1:N, ncol = 1)
    } else {
      # n fold
      rndIds <- sample(x[[unknownVar]]$areaValues[,1], N)
      nsize <- ceiling(N/nfold)
      indexM <- matrix(NA, nrow=nfold, ncol=nsize)
      nfrom <- nto <- 0
      for (i in 1:nfold) {
        nfrom <- nto + 1
        nto <- min(nsize * i, N)
        indexM[i,1:(nto-nfrom+1)] <- sort(rndIds[nfrom:nto])
      }
    }
  } else {
    indexM <- matrix(nfold, nrow = 1)
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=nrow(indexM), width = 50, style = 3)

  xknown <- x

  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:nrow(indexM)) {
      xknown[[unknownVar]] <- subsetDiscreteArea(x[[unknownVar]], indexM[k,], revSel = TRUE)
      unknown <- subsetDiscreteArea(x[[unknownVar]], indexM[k,])$discretePoints
      estResults <- rbind(estResults,
                          ataCoKriging(xknown, unknownVar, unknown, ptVgms, nmax, longlat, oneCondition, meanVal, auxRatioAdj, showProgress = FALSE, nopar = TRUE))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    bInnerParallel <- ncol(indexM) > 2*nrow(indexM)
    if(bInnerParallel) {
      estResults <- c()
      for (k in 1:nrow(indexM)) {
        xknown[[unknownVar]] <- subsetDiscreteArea(x[[unknownVar]], indexM[k,], revSel = TRUE)
        unknown <- subsetDiscreteArea(x[[unknownVar]], indexM[k,])$discretePoints
        estResults <- rbind(estResults,
                            ataCoKriging(xknown, unknownVar, unknown, ptVgms, nmax, longlat, oneCondition, meanVal, auxRatioAdj, showProgress = FALSE, nopar = FALSE))
        if(showProgress) setTxtProgressBar(pb, k)
      }
    } else {
      progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
      estResults <-
        foreach(k = 1:nrow(indexM), .combine = rbind, .options.snow=list(progress=progress),
                .export = c(".crossName",".ataCov",".calcAreaCentroid","subsetDiscreteArea","ataCoKriging",".ataCoKriging.local"),
                .packages = c("sp","gstat","FNN")) %dopar% {
                  xknown[[unknownVar]] <- subsetDiscreteArea(x[[unknownVar]], indexM[k,], revSel = TRUE)
                  unknown <- subsetDiscreteArea(x[[unknownVar]], indexM[k,])$discretePoints
                  ataCoKriging(xknown, unknownVar, unknown, ptVgms, nmax, longlat, oneCondition, meanVal, auxRatioAdj, showProgress = FALSE, nopar = TRUE)
                }
      clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
    }
  }
  if(showProgress) close(pb)

  estResults <- estResults[order(estResults$areaId),]
  indx <- match(estResults[,1], x[[unknownVar]]$areaValues[,1])
  # estResults$diff <- x[[unknownVar]]$areaValues[indx,4] - estResults[,4]
  estResults$value <- x[[unknownVar]]$areaValues[indx,4]

  return(estResults)
}


## .ataCoKriging.local: [internal use only]. ----
.ataCoKriging.local <- function(x, unknownVar, unknown, ptVgms, nmax=10, longlat=FALSE,
                                oneCondition=FALSE, meanVal=NULL, auxRatioAdj=TRUE, showProgress=TRUE, nopar=FALSE) {

  if(is(unknown, "discreteArea")) unknown <- unknown$discretePoints

  # sort areaId in ascending order.
  unknown <- unknown[sort.int(unknown[,1], index.return = T)$ix,]
  unknownCenter <- .calcAreaCentroid(unknown)

  # neighbor indexes for each unknown point.
  varIds <- sort(names(x))
  nb <- list()
  for (id in varIds) {
    nb[[id]] <- get.knnx(as.matrix(x[[id]]$areaValues[,2:3,drop=F]), as.matrix(unknownCenter[,2:3,drop=F]), nmax)
    nb[[id]]$nn.index <- matrix(x[[id]]$areaValues[,1][nb[[id]]$nn.index], ncol = nmax)
  }
  # only consider covariables within the radius of unknownVar
  for (id in varIds[varIds != unknownVar]) {
    indx <- nb[[id]]$nn.dist > matrix(rep(nb[[unknownVar]]$nn.dist[,nmax] * 1.5, nmax), ncol = nmax)
    nb[[id]]$nn.dist[indx] <- NA
    nb[[id]]$nn.index[indx] <- NA
  }

  unknownAreaIds <- sort(unique(unknown[,1]))

  krigOnce <- function(k) {
    curUnknown <- unknown[unknown[,1] == unknownAreaIds[k], ]

    curx <- list()
    for (id in varIds) {
      if(!hasName(x[[id]], "discretePoints")) {
        x[[id]]$discretePoints <- cbind(x[[id]]$areaValues[,1:3], data.frame(weight=rep(1,nrow(x[[id]]$areaValues))))
        names(x[[id]]$discretePoints)[2:3] <- c("ptx","pty")
      }

      curVals <- x[[id]]$areaValues[x[[id]]$areaValues[,1] %in% nb[[id]]$nn.index[k,],]
      curPts <- x[[id]]$discretePoints[x[[id]]$discretePoints[,1] %in% nb[[id]]$nn.index[k,],]
      if(nrow(curVals) > 0) {
        curx[[id]] <- list(areaValues=curVals, discretePoints=curPts)
      }
    }

    estResult <- ataCoKriging(curx, unknownVar, curUnknown, ptVgms, nmax=Inf, longlat, oneCondition, meanVal, auxRatioAdj, showProgress=FALSE, nopar=TRUE)
    return(estResult)
  }

  hasCluster <- !is.null(getOption("ataKrigCluster"))
  if(showProgress) pb <- txtProgressBar(min=0, max=length(unknownAreaIds), width = 50, style = 3)

  if(!hasCluster || nopar) {
    estResults <- c()
    for (k in 1:length(unknownAreaIds)) {
      estResults <- rbind(estResults, krigOnce(k))
      if(showProgress) setTxtProgressBar(pb, k)
    }
  } else {
    progress <- function(k) if(showProgress) setTxtProgressBar(pb, k)
    estResults <-
      foreach(k = 1:length(unknownAreaIds), .combine = rbind, .options.snow=list(progress=progress),
              .export = c("x","ataCoKriging",".crossName",".ataCov",".calcAreaCentroid"),
              .packages = c("sp","gstat")) %dopar% {
        krigOnce(k)
              }
    clusterEvalQ(getOption("ataKrigCluster"), "rm(list=ls())")
  }
  if(showProgress) close(pb)

  return(estResults)
}


## .ataCov: [internal use only] Covariance between two discretized area-samples. ----
# Input:
#   areaPts1: first discretized area-sample, data.frame(ptx,pty,weight), weight is normalized.
#   areaPts2: second discretized area-sample, data.frame(ptx,pty,weight), weight is normalized.
#   ptVgm: point scale variogram (gstat vgm).
#	  longlat: indicator whether coordinates are longitude/latitude
.ataCov <- function(areaPts1, areaPts2, ptVgm, longlat=FALSE) {
  disM <- spDists(as.matrix(areaPts1[,1:2,drop=F]), as.matrix(areaPts2[,1:2,drop=F]), longlat=longlat)
  mCov <- variogramLine(ptVgm, covariance=T, dist_vector=disM)
  return(sum(outer(areaPts1[,3], areaPts2[,3]) * mCov))
}


## atpKriging: Area-to-point ordinary Kriging ----
# Input:
#   x: discretized areas, list(discretePoints, areaValues):
#       areaValues: values of areas, data.frame(areaId,centx,centy,value).
#       discretePoints: discretized points of areas, data.frame(areaId,ptx,pty,weight), the weight is normalized.
#   unknown0: single discretized destination area, data.frame(ptx,pty).
#   ptVgm: point scale variogram, ataKrigVgm.
#   nmax: max number of neighborhoods used for interpolation.
#	  longlat: coordinates are longitude/latitude or not.
#   showProgress: show progress bar for batch interpolation (multi destination areas).
#   nopar: for internal use. Disable parallel process in the function even if ataEnableCluster() has been called.
# Output: estimated value of destination area and its variance.
atpKriging <- function(x, unknown0, ptVgm, nmax=10, longlat=FALSE, showProgress=TRUE, nopar=FALSE) {
  unknown <- cbind(areaId=1:nrow(unknown0), unknown0, weight=1)
  return(ataKriging(x, unknown, ptVgm, nmax, longlat, showProgress, nopar))
}


## atpCoKriging: Area-to-point ordinary CoKriging ----
# Input:
#   x: discretized areas, list(
#      `varId1`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)),
#      `varId2`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)),
#       ...,
#      `varIdn`=list(areaValues=data.frame(areaId,centx,centy,value), discretePoints=data.frame(areaId,ptx,pty,weight)))
#   unknown0: unknown points, data.frame(ptx,pty).
#   ptVgms: point scale direct or cross variograms, ataKrigVgm.
#   nmax: max number of neighborhoods used for interpolation for the main variable.
#	  longlat: indicator whether coordinates are longitude/latitude.
#   oneCondition: use oneCondition cokriging, assuming expected means of variables known and constant with the study area.
#   meanVal: expected means of variables for oneCondition cokriging, data.frame(varId,value). If missing, simple mean values of
#      areas from x will be used instead.
#   showProgress: show progress bar for batch interpolation (multi destination areas).
#   nopar: for internal use. Disable parallel process in the function even if ataEnableCluster() has been called.
# Output: estimated value of destination area and its variance.
atpCoKriging <- function(x, unknownVar, unknown0, ptVgms, nmax=10, longlat=FALSE, oneCondition=FALSE,
                         meanVal=NULL, auxRatioAdj=TRUE, showProgress=TRUE, nopar=FALSE) {
  unknown <- cbind(areaId=1:nrow(unknown0), unknown0, weight=1)
  return(ataCoKriging(x, unknownVar, unknown, ptVgms, nmax, longlat, oneCondition, meanVal, auxRatioAdj, showProgress, nopar))
}

