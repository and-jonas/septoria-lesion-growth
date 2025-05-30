
#====================================================================================== -

#HEADER ----

# Author: Jonas Anderegg, ETH Z?rich
# Copyright (C) 2019  ETH Z?rich, Jonas Anderegg (jonas.anderegg@usys.ethz.ch)

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#  
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

#====================================================================================== -


#' Perform recursive feature elimination
#'
#' @param response A character string representing the response variable name. 
#' To avoid unexpected errors, this should be set to "class_label". 
#' Make sure this variable is encoded as a factor for classification. 
#' @param base_learner A character string. Either "cubist" or "ranger". 
#' @param type A character string. Either "classification" or "regression.
#' @param p A numeric between 0 and 1, indicating the proportion of the dataset used for 
#' feature selection and feature selection validation. 
#' @param times A numeric. The number of times feature selection should be repeated. 
#' @param groups A numeric, indicating the number of stratification groups that are constructed 
#' for the selection of a balanced evaluation dataset. 
#' @param parallel Boolean, indicating whether the script should be executed in parallel or serialy.
#' @param subsets A vector of numerics, indicating the subset sizes (numbers of predictors) to evaluate.
#' @param data The object holding the modelling data. 
#' @param ... Any further arguments to pass to caret::train()
#' @return A list object holding the rfe output. Input into tidy_rfe_output. 
perform_rfe <- function(response, base_learner = "ranger", type = "regression",
                        p = 0.75, times = 30, groups = 9, parallel = T, n_cores,
                        subsets, data,
                        ...) {
  
  # check for available output
  available_output <- list.files(savedir, pattern = "[0-9].rds")
  processed_subset <- as.numeric(gsub("\\D+", "", available_output))
  
  # create folds for repeated n-fold cross validation
  set.seed(123)
  index <- caret::createDataPartition(pull(data[response]), p = p, times = times, groups = ifelse(is.numeric(groups), groups, 2))
  
  # retain only not-processed
  if(length(processed_subset) > 0){
    index <- index[-processed_subset]
  }
  # check if anything is left to process, exit otherwise
  if(length(index) == 0){
    print("---All subsets already processed. Moving on. ")
    return(NULL)
  }
  
  # outer re-sampling, using the folds
  # CV of feature selection
  `%infix%` <- ifelse(parallel, `%dopar%`, `%do%`)
  foreach(i=1:length(index)) %infix% {

    #Verbose
    print(paste("resample ", i, "/", length(index), sep = ""))
    
    #use indices to create train and test data sets for the re-sample
    ind <- as.numeric(index[[i]])
    train <- data[ind,]
    test <- data[-ind, ]
    
    # for each subset of decreasing size
    # tune/train rf and select variables to retain
    keep_vars <- drop_vars <- test_perf <- train_perf <- null_perf <- npred <- NULL
    for(j in 1:length(subsets)){
      
      # define new training data
      # except for first iteration, where the full data set is used
      if(exists("newtrain")) {train = newtrain}
      
      # track progress
      print(paste("==> subset size = ", length(train)-1, sep = ""))
      
      # define tune grid
      if(base_learner == "ranger"){
        # adjust mtry parameter to decreasing predictor set
        # maximum mtry at 200
        mtry <- ceiling(seq(ceiling(0.1*length(train[-1])), ceiling(0.66*length(train[-1])), len = 6)) %>% unique()
        if(any(mtry > 200)){
          mtry <- mtry[-which(mtry >= 200)]
        }
        min.node.size <- c(5)
        tune_grid <- expand.grid(mtry = mtry,
                                 splitrule = ifelse(type == "regression", "variance", "gini"),
                                 min.node.size = ifelse(type == "regression", 5, 1)) 
      } else if(base_learner == "cubist"){
        tune_grid <- expand.grid(committees = c(1, 2, 5, 10),
                                 neighbors = c(0))
      }
      
      # define inner re-sampling procedure
      ctrl <- caret::trainControl(method = "repeatedcv",
                                  number = 7,
                                  rep = 1,
                                  verbose = FALSE,
                                  allowParallel = TRUE,
                                  savePredictions = TRUE,
                                  classProbs = ifelse(type == "classification", TRUE, FALSE))
      
      # define model to fit
      formula <- as.formula(paste(response, " ~ .", sep = ""))

      # Set up cluster unless it already exists
      if(!(exists("cl") && inherits(cl, "cluster"))){
        n_cores <- n_cores
        cl <- makeCluster(n_cores, type = "SOCK")  # Use all but one core
        registerDoSNOW(cl)
      }
      
      # tune/train random forest
      fit <- caret::train(formula,
                          data = train,
                          preProc = c("center", "scale"),
                          method = base_learner,
                          tuneGrid = tune_grid,
                          trControl = ctrl,
                          # num.trees = 150,
                          # verbose = TRUE,
                          # importance = "permutation",
                          # parallel = F)
                          ...)
      
      if(type == "regression"){
        # extract predictions and observations of each fold
        predobs_cv <- plyr::match_df(fit$pred, fit$bestTune, on = names(fit$bestTune))
        # Average predictions of the held out samples;
        predobs <- predobs_cv %>% 
          group_by(rowIndex) %>% 
          dplyr::summarize(obs = mean(obs),
                           mean_pred = mean(pred))
        
        # get train performance
        train_perf[j] <- list(get_train_performance(obj=fit))
        
        # get test performance
        test_perf[j] <- list(get_test_performance(obj=fit, data=test))
        
        # get baseline performance
        null_perf[j] <- list(get_baseline_performance(obj=fit, data=train))

      } else if (type == "classification"){
        # get train accuracy
        train_perf[j] <- caret::getTrainPerf(fit)$TrainAccuracy
        # get test accuracy
        test_perf[j] <- get_acc(fit, test, response = response)
      }
      
      # number of predictions used
      npred[[j]] <- length(train)-1
      
      # extract retained variables
      # assign ranks
      # define reduced training data set
      if(j < length(subsets)){
        # extract top variables to keep for next iteration
        imp <- varImp(fit)$importance %>% 
          tibble::rownames_to_column() %>% 
          as_tibble() %>% dplyr::rename(var = rowname)
        # requires aggregation of importance for factor variable levels,
        # if any present
        if(any(sapply(train, is.factor))){
          fct_chr_cols <- train %>%
            select(where(~ is.factor(.) || is.character(.))) %>%
            colnames()
          # remove single factor level importance values
          drop_fct_imp <- paste0("^", fct_chr_cols, collapse = "|")
          drop_fct_imp <- paste(imp$var[grep(drop_fct_imp, imp$var)], collapse = "|")
          # Aggregate importance for factor variables
          fct_agg_imp <- imp %>%
            mutate(
              var = map_chr(imp$var, function(var) {
                # Match variable name with factor column prefixes
                match <- fct_chr_cols[which(startsWith(var, fct_chr_cols))]
                if (length(match) > 0) match else NA_character_
              })
            ) %>%
            group_by(var) %>%
            summarize(
              Overall = sum(Overall, na.rm = TRUE)          ) %>%
            filter(!is.na(var))  # Remove non-factor variables
          # combine factor importance with numeric variable importance
          imp <- imp[!grepl(drop_fct_imp, imp$var),]
          imp <- bind_rows(imp, fct_agg_imp)
        }
        # select the variables to retain
        keep_vars[[j]] <- imp %>%
          arrange(desc(Overall)) %>% slice(1:subsets[j+1]) %>% pull(var)
        # extract variables dropped from dataset
        drop_vars[[j]] <- names(train)[!names(train) %in% c(keep_vars[[j]], response)] %>% 
          tibble::enframe() %>% mutate(rank = length(subsets)-j+1) %>% 
          dplyr::select(value, rank) %>% dplyr::rename(var = value)
        # define new training data
        newtrain <- dplyr::select(train, response, keep_vars[[j]])
        # last iteration
      } else {
        drop_vars[[j]] <- names(train)[names(train) != response] %>% 
          tibble::enframe() %>% mutate(rank = length(subsets)-j+1) %>% 
          dplyr::select(value, rank) %>% rename(var = value)
      }
    } # END OF FEATURE ELIMINATION ON RESAMPLE i
    
    # clean environment 
    rm("newtrain")
    # gather results for resample i
    ranks <- drop_vars %>% do.call("rbind", .)
    # save subset results
    saveRDS(
      list(ranks, train_perf, test_perf, null_perf, npred),
      paste0(savedir, "/out_subset_", i, ".rds"))
    return(list(ranks, train_perf, test_perf, null_perf, npred))
  } # END OF OUTER RESAMPLING
  
  # Stop cluster after all iterations are done
  if (parallel && exists("cl") && inherits(cl, "cluster")) {
    stopCluster(cl)
  }
}

# Create a tidy output
tidy_rfe_output <- function(data, base_learner){
  
  # tidy up list output
  subsets <- unlist(data[[1]][[length(data[[1]])]])
  ranks <- lapply(data, "[[", 1) %>% 
    Reduce(function(dtf1, dtf2) full_join(dtf1, dtf2, by = "var"), .) %>% 
    purrr::set_names(., c("var", paste("Resample", 1:length(data), sep = "")))
  
  # get performance metrics
  Perf <- list()
  for(i in c(1:3)){
    Perf[[i]] <- lapply(data, "[[", i+1) %>% lapply(., cbind, subsets) %>%
      lapply(., as_tibble) %>% 
      Reduce(function(dtf1, dtf2) full_join(dtf1, dtf2, by = "subsets"), .) %>% 
      dplyr::select(subsets, everything()) %>% 
      purrr::set_names(c("subset_size", paste("Resample", 1:length(data), sep = ""))) %>% 
      gather(resample, RMSE, contains("Resample")) %>%
      unnest(c(subset_size, RMSE)) %>% 
      group_by(subset_size) %>%
      arrange(subset_size) %>% ungroup()
  }
  
  # summarise
  P <- Perf %>% 
    bind_rows() %>% 
    dplyr::select(-resample) %>% 
    dplyr::filter(Type != "Null") %>% 
    pivot_longer(cols = RMSE:Rsquared) %>% 
    group_by(subset_size, Type, name) %>% 
    summarise(mean = mean(value),
              sd = sd(value),
              se = se(value))
  N_P <- Perf %>% 
    bind_rows() %>%
    dplyr::filter(Type == "Null") %>% 
    dplyr::select(-resample) %>% 
    pivot_longer(cols = RMSE:Rsquared) %>% 
    group_by(Type, name) %>% 
    summarise(mean = mean(value),
              sd = sd(value),
              se = se(value)) %>% 
    add_column("subset_size" = 0) %>% 
    relocate("subset_size", .before = "Type")
  
  P <- bind_rows(N_P, P)
  
  # average ranks
  robranks <- ranks %>% 
    gather(resample, rank, contains("Resample")) %>%
    group_by(var) %>%
    summarise_at(vars(rank), list(mean = mean, sd = sd, se = se), na.rm = TRUE) %>%
    arrange(mean)
  tidy_out <- list(P, robranks)
  return(tidy_out)
}

# Plot performance profiles
plot_perf_profile <- function(data){
  
  pd <- position_dodge(0.5) # move them .05 to the left and right
  colors = c("darkorange", "steelblue", "slateblue")
  
  labels <- unique(data$name)
  names(labels) <- labels
  if("Rsquared" %in% labels){
    labels[which(labels == "Rsquared")] <- "R²"
  }

  # plot performance profiles
  plot <- ggplot(data, aes(x = subset_size, y = mean, group = Type, color = Type)) +
    geom_point(position = pd, size = 2) +  # Apply dodge to points
    geom_line() +
    geom_errorbar(position = pd, aes(ymin = mean - sd, ymax = mean + sd), width = 1, alpha = 0.5) + 
    scale_color_manual(values = colors) +  # Assign custom colors
    xlab("# Features") + 
    ylab("Metric value (mean ± sd)") +
    facet_wrap(~name, scales = "free_y", labeller = labeller(name = labels)) +
    theme(
      legend.title = element_blank(),
      legend.position = "right",
      panel.background = element_rect(fill = "#E5E5E5")
    )
  
  return(plot)
}

# Plot feature ranks
plot_feature_ranks <- function(data, top_n){
  data <- data %>% slice(1:top_n)
  ggplot(data, aes(x=order, y=mean)) +
    geom_point(size = 2, pch = 21, bg = 4, col = 1) +
    geom_errorbar(aes(ymin=mean-sd, ymax=mean+sd), width=0.5) +
    ylab("Feature rank") +
    xlab("Feature")+
    # Add categories to axis
    scale_x_continuous(
      breaks = data$order,
      labels = data$var,
      expand = c(0,0)
    ) +
    coord_flip() +
    theme_bw() %+replace%
    theme(axis.title.y =  element_blank(),
          plot.title = element_text(size=15, face="bold"),
          panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank())
}

#====================================================================================== -

# Helper function to calculate accuracy
get_acc <- function(model, testdata, response = response) {
  preds_class <- caret::predict.train(model, newdata = testdata[ , names(testdata) != "trt"])
  true_class <- factor(testdata[[response]])
  res <- cbind(preds_class, true_class) %>% data.frame()
  match <- ifelse(res$preds_class == res$true_class, 1, 0) %>% sum()
  acc <- match/nrow(testdata)
}

# Helper function to get RMSE
rmse <- function(actual, predicted) {
  sqrt(mean((actual - predicted) ^ 2))
}

mae <- function(actual, predicted){
  mean(abs(actual - predicted))
}

se <- function(x, na.rm = TRUE) sqrt(var(x)/length(x))

get_train_performance <- function(obj){
  perf <- caret::getTrainPerf(obj)
  rmse <- unname(perf["TrainRMSE"])
  mae <- unname(perf["TrainMAE"])
  r2 <- unname(perf["TrainRsquared"])
  return(data.frame("Type" = "Train", "RMSE" = rmse, "MAE" = mae, "Rsquared" = r2))
}

get_baseline_performance <- function(obj, data){
  ind_train <- obj$control$index
  ind_test <- obj$control$indexOut
  baseline_preds  <- lapply(c(1:length(ind_train)), function(i){
    mean_train <- mean(data[ind_train[[i]], ][[response]])
    obs <- data[ind_test[[i]], ][[response]]
    data.frame(rowIndex = ind_test[[i]],
               obs = obs,
               mean_pred = rep(mean_train, length(ind_test[[i]])))
  })
  baseline_predobs <- do.call(rbind, baseline_preds)
  r2 <- cor(baseline_predobs$obs, baseline_predobs$mean_pred)^2
  rmse <- rmse(baseline_predobs$obs, baseline_predobs$mean_pred)
  mae <- mae(baseline_predobs$obs, baseline_predobs$mean_pred)
  return(data.frame("Type" = "Null", "RMSE" = rmse, "MAE" = mae, "Rsquared" = r2))
}

get_test_performance <- function(obj=fit, data=test){
  r2 <- cor(data[[response]], caret::predict.train(obj, data))^2
  rmse <- rmse(data[[response]], caret::predict.train(obj, data))
  mae <- mae(data[[response]], caret::predict.train(obj, data))
  return(data.frame("Type" = "Test", "RMSE" = rmse, "MAE" = mae, "Rsquared" = r2))
}

#====================================================================================== -

# Function to extract temperature course for specific site and time interval
extract_covar <- function(df, from, to) {
  df_ <- df %>% filter(timestamp > from, timestamp <= to)
  return(df_)
}

extract_covars_from_nested <- function(tbl, from, vars)
{
  dat_vars <- list()
  for(i in vars){
    dat_vars[[i]] <- do.call("c", lapply(tbl[[from]], "[[", i))
  }
  if(length(vars)>1){
    vars <- do.call("cbind", dat_vars)
    out <- cbind(tbl, vars)
    out <- as_tibble(out)
  } else {
    out <- as_tibble(dat_vars)
    out <- bind_cols(tbl, out)
  }
  return(out)
}

#====================================================================================== -