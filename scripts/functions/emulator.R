# ==============================================================================
# Identify numeric attributes that behave as categories
#
# Some catchment attributes are stored as numbers but actually represent
# discrete classes. Stream order is a typical example. We flag numeric
# variables that contain only whole numbers and have a limited number of
# distinct values.
# ==============================================================================

is_integer_categorical <- function(x, max_levels = 20L) {
  
  if (!is.numeric(x)) return(FALSE)
  
  values <- x[!is.na(x)]
  
  if (length(values) == 0L) return(FALSE)
  
  all_integer <- all(abs(values - round(values)) < .Machine$double.eps^0.5)
  low_cardinality <- length(unique(values)) <= max_levels
  
  all_integer && low_cardinality
}


# ==============================================================================
# Prepare emulator predictors
#
# The same preprocessing recipe must be used during training and prediction.
# Categorical levels are defined from the complete CAMELS-NZ attribute database
# so that a category present only in a held-out catchment remains valid during
# regionalisation experiments.
# ==============================================================================

prepare_predictors <- function(data,
                               parameter_names,
                               attribute_names,
                               fit = TRUE,
                               recipe = NULL,
                               categorical_levels = NULL) {
  
  colsX <- paste0("p", seq_along(parameter_names))
  predictors <- c(colsX, attribute_names)
  
  x <- data[, predictors, drop = FALSE]
  
  # ============================================================================
  # Fit preprocessing recipe
  # ============================================================================
  
  if (fit) {
    
    # --------------------------------------------------------------------------
    # Identify categorical predictors
    #
    # The categorical definition was established from the complete CAMELS-NZ
    # attribute database before training. It must not be inferred again from the
    # current fold, because a continuous attribute may appear integer-valued when
    # only a few basins are available.
    # --------------------------------------------------------------------------
    
    categorical <- intersect(names(x), names(categorical_levels))
    
    if (length(categorical) > 0L) {
      message("Categorical predictors: ", paste(categorical, collapse = ", "))
    }
    
    # --------------------------------------------------------------------------
    # Apply global CAMELS-NZ categorical levels
    #
    # These levels must not be derived only from the training basins. Otherwise
    # a category occurring only in a held-out catchment would be converted to NA.
    # --------------------------------------------------------------------------
    
    if (length(categorical) > 0L) {
      
      if (is.null(categorical_levels)) {
        stop("categorical_levels must be supplied when fitting preprocessing with categorical predictors.")
      }
      
      missing_levels <- setdiff(categorical, names(categorical_levels))
      
      if (length(missing_levels) > 0L) {
        stop("No global categorical levels supplied for: ",
             paste(missing_levels, collapse = ", "))
      }
      
      for (nm in categorical) {
        x[[nm]] <- factor(as.character(x[[nm]]), levels = categorical_levels[[nm]])
      }
    }
    
    # --------------------------------------------------------------------------
    # Convert predictors to a common numerical design matrix
    #
    # Both RF and XGBoost use the same matrix so that categorical attributes are
    # treated consistently across emulator algorithms.
    # --------------------------------------------------------------------------
    
    mm <- model.matrix(~ . - 1, data = x)
    
    if (nrow(mm) != nrow(x)) {
      stop("Preprocessing changed the number of rows: ", nrow(x), " -> ", nrow(mm))
    }
    
    if (any(!is.finite(mm))) {
      stop("Non-finite values found in the predictor design matrix.")
    }
    
    recipe <- list(
      parameter_names = parameter_names,
      attribute_names = attribute_names,
      predictors = predictors,
      categorical = categorical,
      attribute_levels = categorical_levels[categorical],
      design_columns = colnames(mm)
    )
    
  } else {
    
    # ==========================================================================
    # Apply an existing preprocessing recipe
    # ==========================================================================
    
    if (is.null(recipe)) {
      stop("A preprocessing recipe must be supplied when fit = FALSE.")
    }
    
    # --------------------------------------------------------------------------
    # Apply the same categorical levels used during training
    # --------------------------------------------------------------------------
    
    if (length(recipe$categorical) > 0L) {
      
      for (nm in recipe$categorical) {
        
        original_value <- as.character(x[[nm]])
        x[[nm]] <- factor(original_value, levels = recipe$attribute_levels[[nm]])
        
        became_na <- is.na(x[[nm]]) & !is.na(original_value)
        
        if (any(became_na)) {
          stop("Unknown categorical value for predictor '", nm, "': ",
               paste(unique(original_value[became_na]), collapse = ", "))
        }
      }
    }
    
    # --------------------------------------------------------------------------
    # Build the prediction design matrix
    # --------------------------------------------------------------------------
    
    mm <- model.matrix(~ . - 1, data = x)
    
    if (nrow(mm) != nrow(x)) {
      stop("Prediction preprocessing changed the number of rows: ",
           nrow(x), " -> ", nrow(mm))
    }
    
    # --------------------------------------------------------------------------
    # Restore columns present during training but absent in this prediction
    #
    # A class may exist globally but not occur in the current basin. Its dummy
    # variable should then simply be zero.
    # --------------------------------------------------------------------------
    
    missing <- setdiff(recipe$design_columns, colnames(mm))
    
    if (length(missing) > 0L) {
      mm <- cbind(mm, matrix(0, nrow = nrow(mm), ncol = length(missing),
                             dimnames = list(NULL, missing)))
    }
    
    # --------------------------------------------------------------------------
    # Remove unexpected columns and restore exact training column order
    # --------------------------------------------------------------------------
    
    extra <- setdiff(colnames(mm), recipe$design_columns)
    
    if (length(extra) > 0L) {
      mm <- mm[, setdiff(colnames(mm), extra), drop = FALSE]
    }
    
    mm <- mm[, recipe$design_columns, drop = FALSE]
    
    if (any(!is.finite(mm))) {
      stop("Non-finite values found in the prediction design matrix.")
    }
  }
  
  list(data_frame = x, matrix = mm, recipe = recipe)
}


# ==============================================================================
# Train one emulator
# ==============================================================================

train_one_emulator <- function(emulator_type,
                               emulatorData,
                               parameter_names,
                               attribute_names,
                               categorical_levels,
                               experiment,
                               nCores = 1L) {
  
  set.seed(experiment$seed)
  
  if (!nrow(emulatorData)) {
    stop("No emulator training data.")
  }
  
  # Missing static attributes should already have been handled during the
  # CAMELS-NZ preparation and QC stage.
  required <- c(paste0("p", seq_along(parameter_names)), attribute_names, "NKGE")
  
  if (anyNA(emulatorData[, required, drop = FALSE])) {
    stop("NA values remain in emulator training data; run preparation/QC first.")
  }
  
  # Build the common numerical predictor matrix and save its preprocessing recipe
  prep <- prepare_predictors(
    data = emulatorData,
    parameter_names = parameter_names,
    attribute_names = attribute_names,
    fit = TRUE,
    categorical_levels = categorical_levels
  )
  
  y <- emulatorData$NKGE
  
  # ============================================================================
  # Random Forest
  # ============================================================================
  
  if (emulator_type == "RF") {
    
    model <- ranger::ranger(
      x = prep$matrix,
      y = y,
      num.trees = experiment$rf_trees,
      mtry = max(1L, ceiling(experiment$rf_mtry_fraction * ncol(prep$matrix))),
      write.forest = TRUE,
      min.node.size = 5,
      num.threads = min(10L, nCores)
    )
    
    pred <- model$predictions
    rowsTrain <- seq_len(nrow(emulatorData))
    rowsWatch <- integer(0)
    
  } else {
    
    # ==========================================================================
    # XGBoost settings shared by GBMv01 and GBMv02
    # ==========================================================================
    
    xgb_params <- list(
      objective = "reg:squarederror",
      booster = "gbtree",
      nthread = min(10L, nCores),
      eta = 0.05,
      max_depth = 6,
      subsample = 0.7,
      colsample_bytree = 0.7,
      num_parallel_tree = 1,
      lambda = 1,
      alpha = 0,
      min_child_weight = 10,
      eval_metric = "rmse"
    )
    
    # ==========================================================================
    # GBMv01: all available training data
    # ==========================================================================
    
    if (emulator_type == "GBMv01") {
      
      rowsTrain <- seq_len(nrow(emulatorData))
      rowsWatch <- integer(0)
      
      dtrain <- xgboost::xgb.DMatrix(prep$matrix, label = y)
      
      model <- xgboost::xgb.train(
        params = xgb_params,
        data = dtrain,
        nrounds = experiment$xgb_nrounds,
        verbose = 1
      )
      
      pred <- predict(model, dtrain)
      
      # ==========================================================================
      # GBMv02: internal train/watch split for early stopping
      # ==========================================================================
      
    } else if (emulator_type == "GBMv02") {
      
      rowsTrain <- sample(seq_len(nrow(emulatorData)), floor(0.8 * nrow(emulatorData)))
      rowsWatch <- setdiff(seq_len(nrow(emulatorData)), rowsTrain)
      
      dtrain <- xgboost::xgb.DMatrix(
        prep$matrix[rowsTrain, , drop = FALSE],
        label = y[rowsTrain]
      )
      
      dwatch <- xgboost::xgb.DMatrix(
        prep$matrix[rowsWatch, , drop = FALSE],
        label = y[rowsWatch]
      )
      
      model <- xgboost::xgb.train(
        params = xgb_params,
        data = dtrain,
        nrounds = experiment$xgb_nrounds,
        watchlist = list(train = dtrain, watch = dwatch),
        early_stopping_rounds = experiment$xgb_early_stopping,
        verbose = 1
      )
      
      pred <- rep(NA_real_, nrow(emulatorData))
      pred[rowsTrain] <- predict(model, dtrain)
      pred[rowsWatch] <- predict(model, dwatch)
      
    } else {
      
      stop("Unknown emulator type: ", emulator_type)
    }
  }
  
  emulatorData$eNKGE <- pred
  
  list(
    model = model,
    model_type = emulator_type,
    preprocessing = prep$recipe,
    emulatorData = emulatorData,
    rowsTrain = rowsTrain,
    rowsWatch = rowsWatch
  )
}


# ==============================================================================
# Predict emulator performance for new parameter sets / catchments
# ==============================================================================

predict_emulator <- function(summary, newdata) {
  
  prep <- prepare_predictors(
    data = newdata,
    parameter_names = summary$preprocessing$parameter_names,
    attribute_names = summary$preprocessing$attribute_names,
    fit = FALSE,
    recipe = summary$preprocessing
  )
  
  # ============================================================================
  # Random Forest
  # ============================================================================
  
  if (summary$model_type == "RF") {
    
    y <- as.numeric(
      predict(summary$model, data = prep$matrix, num.threads = 1)$predictions
    )
    
    # ============================================================================
    # XGBoost
    # ============================================================================
    
  } else {
    
    d <- xgboost::xgb.DMatrix(prep$matrix)
    
    y <- as.numeric(predict(summary$model, d, validate_features = FALSE))
  }
  
  # A valid emulator prediction should return exactly one value for every row
  # supplied to the model.
  if (length(y) != nrow(newdata)) {
    stop("Emulator prediction returned ", length(y), " value(s) for ", nrow(newdata), " input row(s).")
  }
  
  if (any(!is.finite(y))) {
    stop("Emulator returned non-finite prediction(s).")
  }
  
  y
}