
#====================================================================================== -

#HEADER ----

# Author: Jonas Anderegg, ETH Zürich
# Copyright (C) 2025  ETH Zürich, Jonas Anderegg (jonas.anderegg@usys.ethz.ch)

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

rm(list = ls())
.libPaths("T:/R4Userlibs")

# install required packages
list.of.packages <- c("tidyverse", "caret", "ranger", "foreach", "parallel", "doSNOW", "corrplot", "ggpubr")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages, lib = "T:/R4Userlibs", dependencies = TRUE, repos='https://stat.ethz.ch/CRAN/')

# load packages
library(tidyverse)
library(caret)
library(ranger)
library(foreach)
library(doParallel)
library(doSNOW)
library(corrplot)
library(ggpubr)

# set the working directory
setwd("C:/Users/anjonas/RProjects/lesionProc")

# load custom functions for analysis
source("./R/utils/feature_selection.R" )

# define scenario
target_trait <- "diff_area_pp_y_norm_chr"

# set paths
data_path <- "./output/data/"
out_path <- "./output/"
figure_path <- "./output/figures/"
run_paths <- paste0(out_path, c("rfe/run0", "rfe/run1", "rfe/run2"))

# make output directories
for (d in c(out_path, figure_path, run_paths)){
  if (!dir.exists(d)) {
    dir.create(d, recursive = TRUE)
  }
}

# =================================================================================================== -
# Prepare feature data ----
# =================================================================================================== -

# load training data
data0 <- readRDS(paste0(data_path, "subset_step2.rds"))

# get relevant variables
data <- data0 %>% 
  extract_covars_from_nested(., from = "design", vars = "genotype_name") %>%
  dplyr::select(all_of(target_trait), exp_UID, genotype_name, batch, lesion_nr, diff_time, diff_gdd,  
                mean_interval_temp, cv_interval_temp, mean_interval_rh, cv_interval_rh, contains("lag_")) %>% 
  dplyr::select(-lag_timestamp, -lag_timestamp_leaf,
                -lag_perimeter, -lag_analyzable_perimeter, -lag_occluded_perimeter) %>% 
  dplyr::filter(complete.cases(.))

# drop redundant variables
data <- data %>%
  dplyr::select(-lag_max_p_density) # redundant to lag_max_l_density

# adjust data types
data <- data %>% 
  # two factors
  mutate(across(c(exp_UID, genotype_name, batch), as.factor)) %>% 
  # rest is numeric
  mutate(across(c(lesion_nr:lag_lesion_age_gdd), as.numeric))

# =================================================================================================== -
# Plot feature data ----
# =================================================================================================== -

# plot training data (numeric variables only)
long <- data %>%
  pivot_longer(cols = lesion_nr:lag_lesion_age_gdd, names_to = "feature", values_to = "value")

scaling_function <- function(X) (X - min(X, na.rm = TRUE))/diff(range(X, na.rm = TRUE))*1
scaledat <-  long %>% group_by(feature) %>% group_nest() %>% 
  mutate(scaled_val = purrr::map(data,~scaling_function(.$value))) %>% 
  unnest(cols = c(data, scaled_val)) %>% ungroup()

plot <- ggplot(scaledat) +
  geom_density(aes(x=scaled_val, group = exp_UID, fill = exp_UID), alpha = 0.2) +
  scale_x_continuous(breaks = c(0, 0.5, 1), limits = c(0, 1)) +
  facet_wrap(~feature, scales = "free_y") +
  ylab("Density") + xlab("Scaled feature value") +
  theme_bw() +
  theme(
    panel.border = element_blank(),
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank(),
    strip.background = element_blank(),
    strip.text = element_text(face="bold", size = 5)
  )

png(paste0(figure_path, "variable_distr_nolag.png"),
    width = 12, height = 7, units = 'in', res = 600)
plot(plot)
dev.off()

# UNSCALED
plot <- ggplot(long) +
  geom_density(aes(x=value, group = exp_UID, fill = exp_UID), alpha = 0.2) +
  facet_wrap(~feature, scales = "free") +
  ylab("Density") + xlab("Scaled feature value") +
  theme_bw() +
  theme(
    panel.border = element_blank(),
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank(),
    axis.ticks.y = element_blank(),
    axis.text.y = element_blank(),
    axis.text.x = element_text(angle = 45, hjust = 1),
    strip.background = element_blank(),
    strip.text = element_text(face="bold", size = 10)
  )
png(paste0(figure_path, "variable_distr_nolag_noscale.png"),
    width = 18, height = 10.5, units = 'in', res = 600)
plot(plot)
dev.off()

# =================================================================================================== -
# >> Perform rfe run 0 ----
# =================================================================================================== -

# set output path
rfe_output_path <- paste0(out_path, "rfe/run0")

# candidate set of the number of predictors to evaluate
subsets <- c(seq(from = length(data)-1, to = 10, by = -3),
             seq(from = 11, to = 1, by = -1))

# define all parameters for rfe
response = target_trait
base_learner = "ranger"
type = "regression"
p = 0.8
times = 30
data = data
importance = "permutation"
num.trees = 150
n_cores = 24
parallel = F
savedir = rfe_output_path

# perform recursive feature elimination
rfe <- perform_rfe(response = response, base_learner = base_learner, type = type,
                   p = p, times = times, 
                   subsets = subsets, data = data,
                   importance = importance,
                   num.trees = num.trees, n_cores = n_cores, parallel = parallel,
                   savedir = savedir)

# =================================================================================================== -
# Evaluate rfe output run 0----
# =================================================================================================== -

# load rfe output
rfe_output_path <- paste0(out_path, "rfe/run0")
subset_output_files <- list.files(rfe_output_path, 
                                  pattern = "[0-9].rds",
                                  full.names = T)

rfe <- lapply(subset_output_files, readRDS)

# create a tidy output
tidy <- tidy_rfe_output(data = rfe, base_learner = "ranger")

# get performance profile
prof <- plot_perf_profile(data = tidy[[1]])
png(paste0(rfe_output_path, "/perf_prof.png"), width = 10, height = 3.5, units = 'in', res = 400)
plot(prof)
dev.off()

# get feature ranks
ranks <- tidy[[2]] %>% tibble::rowid_to_column("order") %>% 
  mutate(order = as.numeric(1-order))
ranksplot <- plot_feature_ranks(ranks, top_n = nrow(ranks))
# save plot
png(paste0(rfe_output_path, "/feature_ranks.png"), width = 8, height = 5, units = 'in', res = 300)
plot(ranksplot)
dev.off()

# =================================================================================================== -
# Feature correlations and removal ----
# =================================================================================================== -

top_features <- ranks$var
top_data <- data %>% dplyr::select(any_of(top_features)) %>% 
  filter(complete.cases(.))

# drop factors
top_data <- top_data[, !sapply(top_data, is.factor)]

M<-cor(top_data)

png(paste0(rfe_output_path, "/feature_corr.png"), width = 10, height =10, units = 'in', res = 300)
corrplot(M, addCoef.col = "black", tl.col="black", tl.srt=45,
         method = "color", type="upper", diag=FALSE, 
         number.cex = 0.35, tl.cex= 0.5)
dev.off()

# find highly correlated variables
highly_correlated <- as.data.frame(as.table(M)) %>%
  filter(Var1 != Var2, abs(Freq) > 0.925) %>%
  group_by(Freq) %>% 
  slice(1) %>% ungroup() %>% 
  arrange(desc(abs(Freq))) %>% 
  as.data.frame()

# stop if there are no highly correlated variables left
stopifnot(nrow(highly_correlated) > 0)

# add variable to retain (lower mean rank)
outlines <- list()
for (row in 1:nrow(highly_correlated)){
  line <- highly_correlated[row, ]
  out_line <- highly_correlated[row, ]
  var1 <- as.character(line$Var1)
  var2 <- as.character(line$Var2)
  rank_var1 <- ranks[ranks$var == var1, ]$mean
  rank_var2 <- ranks[ranks$var == var2, ]$mean
  idx = which.max(c(rank_var1, rank_var2))
  out_line$drop <- line[, idx]
  outlines[[row]]<- out_line
}
out_df <- do.call("rbind", outlines)
drop_vars <- unique(out_df$drop)

newdata <- data[, !(names(data) %in% drop_vars)]
saveRDS(newdata, paste0(rfe_output_path, "/reduced_traindat.rds"))

# drop factors
newdata_corr <- newdata[, !sapply(newdata, is.factor)]

M <- cor(newdata_corr)

png(paste0(rfe_output_path, "/feature_corr_postrem.png"), width = 10, height =10, units = 'in', res = 300)
corrplot(M, addCoef.col = "black", tl.col="black", tl.srt=45,
         method = "color", type="upper", diag=FALSE, 
         number.cex = 0.35, tl.cex= 0.5)
dev.off()

# =================================================================================================== -
# >> Perform rfe run 1 on feature subset ----
# =================================================================================================== -

# load filtered data from run1
data <- readRDS(paste0(rfe_output_path, "/reduced_traindat.rds"))

# set new output path
rfe_output_path <- paste0(base_output_path, "/run1")

# candidate set of the number of predictors to evaluate
subsets <- c(seq(from = length(data)-1, to = 10, by = -3),
             seq(from = 9, to = 1, by = -1))

# perform rfe
savedir = rfe_output_path
rfe <- perform_rfe(response = response, base_learner = base_learner, type = type,
                   p = p, times = times, 
                   subsets = subsets, data = data,
                   importance = importance,
                   num.trees = num.trees, n_cores = n_cores, parallel = parallel,
                   savedir = savedir)

# =================================================================================================== -
# Evaluate rfe output run 1 ----
# =================================================================================================== -

# load rfe output
subset_output_files <- list.files(rfe_output_path, 
                                  pattern = "[0-9].rds",
                                  full.names = T)

rfe <- lapply(subset_output_files, readRDS)

# create a tidy output
tidy <- tidy_rfe_output(rfe, base_learner = "ranger")

# get performance profile
prof <- plot_perf_profile(data = tidy[[1]])
png(paste0(rfe_output_path, "/perf_prof.png"), width = 10, height = 3.5, units = 'in', res = 400)
plot(prof)
dev.off()

# get feature ranks
ranks <- tidy[[2]] %>% tibble::rowid_to_column("order") %>% 
  mutate(order = as.numeric(1-order))
ranksplot <- plot_feature_ranks(ranks, top_n = nrow(ranks))
# save plot
png(paste0(rfe_output_path, "/feature_ranks.png"), width = 8, height = 4, units = 'in', res = 300)
plot(ranksplot)
dev.off()

# =================================================================================================== -
# Feature correlations and removal ----
# =================================================================================================== -

top_features <- ranks$var
top_data <- data %>% dplyr::select(any_of(top_features)) %>% 
  filter(complete.cases(.))

# drop factors
top_data <- top_data[, !sapply(top_data, is.factor)]

M<-cor(top_data)

png(paste0(rfe_output_path, "/feature_corr.png"), width = 10, height =10, units = 'in', res = 300)
corrplot(M, addCoef.col = "black", tl.col="black", tl.srt=45,
         method = "color", type="upper", diag=FALSE, 
         number.cex = 0.35, tl.cex= 0.5)
dev.off()

# find highly correlated variables
highly_correlated <- as.data.frame(as.table(M)) %>%
  filter(Var1 != Var2, abs(Freq) > 0.85) %>%
  group_by(Freq) %>% 
  slice(1) %>% ungroup() %>% 
  arrange(desc(abs(Freq))) %>% 
  as.data.frame()

# stop if there are no highly correlated variables left
stopifnot(nrow(highly_correlated) > 0)

# add variable to retain (lower mean rank)
ranks
outlines <- list()
for (row in 1:nrow(highly_correlated)){
  line <- highly_correlated[row, ]
  out_line <- highly_correlated[row, ]
  var1 <- as.character(line$Var1)
  var2 <- as.character(line$Var2)
  rank_var1 <- ranks[ranks$var == var1, ]$mean
  rank_var2 <- ranks[ranks$var == var2, ]$mean
  idx = which.max(c(rank_var1, rank_var2))
  out_line$drop <- line[, idx]
  outlines[[row]]<- out_line
}
out_df <- do.call("rbind", outlines)
drop_vars <- unique(out_df$drop)

newdata <- data[, !(names(data) %in% drop_vars)]
saveRDS(newdata, paste0(rfe_output_path, "/reduced_traindat.rds"))

# drop factors
newdata_corr <- newdata[, !sapply(newdata, is.factor)]

M <- cor(newdata_corr)

png(paste0(rfe_output_path, "/feature_corr_postrem.png"), width = 10, height =10, units = 'in', res = 300)
corrplot(M, addCoef.col = "black", tl.col="black", tl.srt=45,
         method = "color", type="upper", diag=FALSE, 
         number.cex = 0.35, tl.cex= 0.5)
dev.off()

# =================================================================================================== -
# >> Perform rfe run 2 on feature subset ----
# =================================================================================================== -

# load filtered data from run1
data <- readRDS(paste0(rfe_output_path, "/reduced_traindat.rds"))

# set new output path
rfe_output_path <- paste0(base_output_path, "/run2")

# candidate set of the number of predictors to evaluate
subsets <- c(seq(from = length(data)-1, to = 10, by = -3),
             seq(from = 9, to = 1, by = -1))

# perform rfe
savedir = rfe_output_path
rfe <- perform_rfe(response = response, base_learner = base_learner, type = type,
                   p = p, times = times, 
                   subsets = subsets, data = data,
                   importance = importance,
                   num.trees = num.trees, n_cores = n_cores, parallel = parallel,
                   savedir = savedir)

# =================================================================================================== -
# Evaluate rfe output run 2 ----
# =================================================================================================== -

# load rfe output
subset_output_files <- list.files(rfe_output_path, 
                                  pattern = "[0-9].rds",
                                  full.names = T)

rfe <- lapply(subset_output_files, readRDS)

# create a tidy output
tidy <- tidy_rfe_output(rfe, base_learner = "ranger")

# get performance profile
prof <- plot_perf_profile(data = tidy[[1]])
png(paste0(rfe_output_path, "/perf_prof.png"), width = 10, height = 3.5, units = 'in', res = 400)
plot(prof)
dev.off()

# get feature ranks
ranks <- tidy[[2]] %>% tibble::rowid_to_column("order") %>% 
  mutate(order = as.numeric(1-order))
ranksplot <- plot_feature_ranks(ranks, top_n = nrow(ranks))
# save plot
png(paste0(rfe_output_path, "/feature_ranks.png"), width = 8, height = 4, units = 'in', res = 300)
plot(ranksplot)
dev.off()

# plot rank distribution across subsets

subsets <- rfe[[1]][[length(rfe[[1]])]]
ranks <- lapply(rfe, "[[", 1) %>% 
  Reduce(function(dtf1, dtf2) full_join(dtf1, dtf2, by = "var"), .) %>% 
  purrr::set_names(., c("var", paste("Resample", 1:length(rfe), sep = "")))

robranks <- ranks %>% 
  gather(resample, rank, contains("Resample")) %>%
  group_by(var) %>%
  summarise_at(vars(rank), funs(mean, sd, se), na.rm = TRUE) %>%
  arrange(mean)

# Reshape the data to long format
df_long <- ranks %>%
  pivot_longer(cols = starts_with("Resample"), names_to = "Resample", values_to = "Value") %>%
  mutate(var = factor(var, levels = robranks$var))  # Convert to factor with custom order

# Calculate the number of unique values per variable
df_long <- df_long %>%
  group_by(var) %>%
  mutate(unique_vals = n_distinct(Value)) %>%
  ungroup()

pp <- ggplot(df_long, aes(x = Value)) +
  scale_x_continuous(limits = c(0, 20)) +
  geom_density(alpha = 0.2, fill = "black", data = subset(df_long, unique_vals > 1)) +  # Only plot density for variables with >1 value
  geom_point(alpha = 0.2, data = subset(df_long, unique_vals == 1), aes(x = Value, y = 0), shape = 21, size = 2.5, color = "black", fill = "black") +  facet_grid(rows = vars(var), scales = "free_y", switch = "y") +  # Use facet_grid to allow rotated labels
  labs(x = "Rank", fill = "Variable") +
  theme_minimal() +
  theme(
    legend.position = "none",  # Hide legend
    strip.placement = "outside",  # Place strip labels outside plot panels
    strip.text.y.left = element_text(angle = 0, hjust = 1, size = 5),  # Correctly rotate strip labels
    axis.text.y = element_blank(),  # Remove y-axis tick labels
    axis.ticks.y = element_blank(),  # Remove y-axis ticks
    panel.spacing = unit(0, "lines"),  # Remove space between facets
    strip.background = element_blank(),  # Remove background from strip labels
    panel.grid = element_blank(),
    axis.title.y = element_blank()
  )

png(paste0(figure_path, "ranks_distr.png"), width = 3.5, height = 4, units = 'in', res = 400)
plot(pp)
dev.off()

# ============================================================================== -
# FINAL MODEL ----
# ============================================================================== -

# get top 20 features
features <- robranks$var[1:20]

# get corresponding subset of the data
data <- readRDS(paste0(base_output_path, "/run1/reduced_traindat.rds"))
data <- data %>% 
  dplyr::select(diff_area_pp_y_norm_chr, all_of(features))

# hyper-parameters
mtry <- ceiling(seq(ceiling(0.1*length(data[-1])), ceiling(0.66*length(data[-1])), len = 6)) %>% unique()
min.node.size = c(1, 3, 5, 10, 20)
sample.fraction = c(0.5, 0.7, 0.9, 1.0)
num.trees = c(75, 150, 250, 500)
splitrule = c("variance", "extratrees", "maxstat")
tune_grid <- expand.grid(
  mtry = mtry,
  splitrule = c("variance", "extratrees"),
  min.node.size = c(1, 3, 5, 10)
)
response = target_trait
base_learner = "ranger"

#define inner re-sampling procedure
ctrl <- caret::trainControl(method = "repeatedcv",
                            number = 10,
                            rep = 5,
                            verbose = TRUE,
                            allowParallel = TRUE,
                            savePredictions = TRUE,
                            classProbs = FALSE)

#define model to fit
formula <- as.formula(paste(response, " ~ .", sep = ""))

# Set up cluster unless it already exists
if(!(exists("cl") && inherits(cl, "cluster"))){
  n_cores <- 32
  cl <- makeCluster(n_cores, type = "SOCK")  # Use all but one core
  registerDoSNOW(cl)
}

#tune/train random forest
fit <- caret::train(formula,
                    data = data,
                    preProc = c("center", "scale"),
                    method = base_learner,
                    tuneGrid = tune_grid,
                    trControl = ctrl,
                    importance = "permutation")
saveRDS(fit, paste0(base_output_path, "/final_rf_fit.rds"))

# Stop cluster after all iterations are done
if (parallel && exists("cl") && inherits(cl, "cluster")) {
  stopCluster(cl)
}

# re-load and evaluate
fit <- readRDS(paste0(base_output_path, "/final_rf_fit.rds"))
caret::getTrainPerf(fit)

# evaluate performance
predobs_cv <- plyr::match_df(fit$pred, fit$bestTune, on = names(fit$bestTune))
predobs <- predobs_cv %>%
  group_by(rowIndex) %>%
  dplyr::summarize(obs = mean(obs),
                   mean_pred = mean(pred),
                   sd_pred = sd(pred))
r <- cor(predobs$obs, predobs$mean_pred)

# limit data range (here: only for plotting)
facet_limits <- predobs %>%
  summarise(
    x_min = quantile(obs, 0.005),
    x_max = quantile(obs, 0.995),
    y_min = quantile(mean_pred, 0.005),
    y_max = quantile(mean_pred, 0.995)
  )
predobs_sub <- predobs %>% 
  filter(obs >= facet_limits$x_min & obs <= facet_limits$x_max & mean_pred >= facet_limits$y_min & mean_pred <= facet_limits$y_max)

# Fit a median quantile regression model
qr_models <- predobs_sub %>% 
  nest() %>%
  mutate(linear_q = purrr::map(data, ~ rq(obs ~ mean_pred, data = .)), 
         loess_q = purrr::map(data, ~ lprq(x = .$mean_pred, 
                                           y = .$obs, 
                                           h = (range(.$mean_pred)[2]-range(.$mean_pred)[1])/20, 
                                           tau = .5)),
         new_data = purrr::map(data, ~ data.frame(mean_pred  = seq(min(.$mean_pred ), max(.$mean_pred ), length.out = 1000))))

# Make predictions for both QR and LPQR models
qr_models2 <- qr_models %>% 
  mutate(
    predicted_qr = purrr::map2(linear_q, new_data, ~ predict(.x, newdata = .y)),
    predicted_lpqr = purrr::map2(loess_q, new_data, ~ {
      fit_values <- .x$fv
      predict_values <- approx(.x$xx, fit_values, xout = .y$mean_pred)$y
      return(predict_values)
    })
  )
predictions <- qr_models2 %>% 
  dplyr::select( new_data, predicted_qr, predicted_lpqr) %>% 
  unnest(cols = c(new_data, predicted_qr, predicted_lpqr))

# add pseudo R2
qr_models3 <- qr_models2 %>% 
  mutate(pseudo_r2 = purrr::map2(data, linear_q, ~ compute_pseudoR2(.x, response = "obs", qr_model = .y)))

# extract r2
qr_models4 <- qr_models3 %>% 
  mutate(r2 = map_dbl(pseudo_r2, 1))

# small subset
num_bins <- 10  
small_subset <- predobs_sub %>%
  mutate(bin = ntile(mean_pred, num_bins)) %>%  # Divide into equal bins
  group_by(bin) %>%
  slice_sample(n = 10) %>%  # Sample one point per bin
  ungroup()

# Pairwise correlations
library(ggpubr)
p <- ggplot(data = predobs_sub, aes(x = mean_pred, y = obs)) +
  geom_point(size = 2, alpha = 0.02) +
  geom_errorbarh(data = small_subset, aes(xmin = mean_pred - sd_pred, xmax = mean_pred + sd_pred),
                 height = 0, color = "slateblue", alpha = 0.7) +
  geom_point(data = small_subset, color = "slateblue") +
  geom_abline(intercept = 0, slope = 1, lty = 2) +
  geom_line(data = predictions, aes(y = predicted_lpqr, x = mean_pred), color = "green", size = 1) +
  geom_line(data = predictions, aes(y = predicted_qr, x = mean_pred), size = 1, color = "yellow") +
  xlab("Predicted Lesion Growth") + ylab("Measured Lesion Growth") +
  geom_text(data = qr_models4, aes(x = Inf, y = Inf, label = paste0("R²: ", round(r2, 2))),
            hjust = 1.5, vjust = 2, inherit.aes = FALSE) +
  theme(strip.background = element_blank(),
        panel.background = element_rect(fill = "#E5E5E5")) 

png(paste0(figure_path, "predobs.png"), width = 5, height = 4, units = 'in', res = 300)
plot(p)
dev.off()
