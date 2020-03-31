# Estimate numbers of people leaving Wuhan by day 
devtools::install_github("teunbrand/ggh4x")
devtools::install_github("reconhub/projections")
pacman::p_load(tidyverse,lubridate,sf,bpmodels,RColorBrewer,imputeTS,incidence,projections,distcrete,epitrix, tsibble,ggh4x)


set.seed(1)

# Read in Baidu overall index mobilty leaving Wuhan 2019 & 2020
baidu <- read_csv("data/scaling_baidu_mobility_index.csv") %>% 
  mutate(Date = dmy(Date))

# Read in prf connectivity matrix export (sum of rows = total index)
connect_all <- readRDS("data/china_prf_connectivity_0101_0301.rds")

# Dates where matrix is available
dates <- connect_all$date

# Read in shapefile
shp <- readRDS("data/china_shp.rds") %>% 
  st_as_sf()

# Just names 
names <- shp %>% 
  as_tibble() %>% 
  filter(lvl == "prf") %>% 
  left_join(.,  shp %>% 
              as_tibble() %>% 
              filter(lvl == "prv") , by= c("prv"="prv")) %>% 
  as_tibble() %>% 
  select(CNTY_CODE = CNTY_CODE.x, PYNAME = PYNAME.x, prv= PYNAME.y)

# Get codes function
getcodes <- function(){
  return(names) %>% 
    view()
}

# Function to look at total travller number from Wuhan 
trav_from_wuhan <- function(prf_code, scale){
  
  
  # Observed flows from Wuhan for 2020 
  index_flows <- list()
  
  for (i in 1:length(dates)) {index_flows[[i]]<- 
    
    connect_all$connect[[i]] %>% 
    as_tibble() %>% 
    filter(from==420100) %>% 
    t() %>% 
    as.data.frame() %>% 
    mutate(code= rownames(.)) %>% 
    as.tibble() %>% 
    mutate(index_flow20 = as.numeric(as.character(V1))) %>% 
    select(-V1) %>% 
    filter(code != "from") %>%
    mutate(index_20 = baidu %>% 
             filter(Date == as.Date(dates[i])) %>% 
             select(baidu_index20) %>% 
             pull()) %>% 
    mutate(index_19 = baidu %>% 
             filter(Date == as.Date(dates[i])) %>% 
             select(baidu_index19) %>% 
             pull()) %>% 
    mutate(flow_percent_20 = index_flow20/index_20) %>%
    mutate(index_flow19 = NA, flow_percent_19 = NA) %>%
    mutate(date = dates[i])
  
  }
  
  # Bind rows of flow data 
  index_flows_data <- bind_rows(index_flows)
  
  dayweek19 <- baidu %>% 
    filter(Date >= as.Date("2020-01-06") & Date <= as.Date("2020-01-10") | Date >= as.Date("2020-02-08") ) %>% 
    mutate(day = wday(Date)) %>% 
    group_by(day) %>% 
    summarise(mean19= mean(baidu_index19))
  
  # mean of non-chunyun post-shutdown index 2020 - weekday                  
  dayweek20 <- baidu %>% 
    filter(Date >= as.Date("2020-02-08")) %>% 
    mutate(day = wday(Date)) %>% 
    group_by(day) %>% 
    summarise(mean20= mean(baidu_index20, na.rm = TRUE))
  
  # Full total baidu estimates for 4 all scenarios
  baidu_comp <- baidu %>% 
    tidyr::complete(Date= seq.Date(min(as.Date("2019-11-23")), max(baidu$Date), by= "day")) %>% 
    mutate(day = wday(Date)) %>% 
    left_join(., dayweek19, by = c("day"="day")) %>% 
    left_join(., dayweek20, by = c("day"="day")) %>% 
    mutate(baidu_index19 = if_else(Date >= as.Date("2019-11-23") & Date <= as.Date("2019-12-31"),mean19, baidu_index19)) %>% 
    mutate(baidu_index20 = if_else(Date >= as.Date("2019-11-23") & Date <= as.Date("2019-12-31"), mean19, baidu_index20)) %>% 
    mutate(baidu_index20 = if_else(Date >= as.Date("2020-03-03"), mean20, baidu_index20)) %>% 
    mutate(baidu_index19non = if_else(Date >= as.Date("2020-01-06") & Date <= as.Date("2020-01-10") | Date >= as.Date("2020-02-08") ,baidu_index19, mean19)) %>% 
    mutate(baidu_index20non = if_else(Date > as.Date("2020-01-23"), baidu_index20, baidu_index19non))
  
  # Join baidu total with observed flows
  new_baidu <- left_join(baidu_comp, index_flows_data %>% 
                           filter(code == prf_code),
                         by= c("Date"="date")) %>% 
    mutate(index_flow19non = NA, flow_percent_19non = NA, flow_percent_20non = NA, index_flow20non = NA) %>% 
    select(code, date= Date, baidu_index19, baidu_index20, baidu_index19non, baidu_index20non, flow_percent_19, flow_percent_20, flow_percent_19non,flow_percent_20non, index_flow19, index_flow20, index_flow19non, index_flow20non)
  
  # Interpolate values for missing values in observed period and calulate flows
  mid_baidu <- new_baidu %>% 
    filter(date >= as.Date("2020-01-01")) %>% 
    mutate(flow_percent_20 = na_interpolation(flow_percent_20)) %>% 
    mutate(index_flow20 = baidu_index20*flow_percent_20) %>% 
    mutate(flow_percent_19 =  as.numeric(if_else(date <= as.Date("2020-01-19"), flow_percent_20, 
                                                 sum(index_flow20, na.rm= TRUE)/sum(baidu_index20, na.rm = TRUE)))) %>% 
    mutate(index_flow19 = baidu_index19*flow_percent_19) %>% 
    mutate(flow_percent_19non = sum(index_flow20, na.rm= TRUE)/sum(baidu_index20, na.rm = TRUE)) %>% 
    mutate(index_flow19non = baidu_index19non*flow_percent_19non) %>% 
    mutate(flow_percent_20non = if_else(date <= as.Date("2020-01-23"), flow_percent_19non,flow_percent_20)) %>% 
    mutate(index_flow20non = baidu_index20non*flow_percent_20non)
  
  # Estimates of flows out of observed range, based on average 2020 flows for whole of observed period
  pre_baidu <- new_baidu %>% 
    filter(date < as.Date(min(mid_baidu$date))) %>% 
    mutate(flow_percent_19 = sum(mid_baidu$index_flow20, na.rm= TRUE)/sum(mid_baidu$baidu_index20, na.rm = TRUE)) %>% 
    mutate(flow_percent_20 = sum(mid_baidu$index_flow20, na.rm= TRUE)/sum(mid_baidu$baidu_index20, na.rm = TRUE)) %>% 
    mutate(flow_percent_19non = sum(mid_baidu$index_flow20, na.rm= TRUE)/sum(mid_baidu$baidu_index20, na.rm = TRUE)) %>% 
    mutate(flow_percent_20non = sum(mid_baidu$index_flow20, na.rm= TRUE)/sum(mid_baidu$baidu_index20, na.rm = TRUE)) %>% 
    mutate(index_flow19 = baidu_index19 * flow_percent_19) %>% 
    mutate(index_flow20 = baidu_index20 * flow_percent_20) %>% 
    mutate(index_flow19non = baidu_index19non * flow_percent_19non) %>% 
    mutate(index_flow20non = baidu_index20non*flow_percent_20non) %>%
    mutate(code = prf_code) %>% 
    mutate(code = as.character(code))
  
  # Combinded observed and estimated - for 2020 after 12th Feb percentage = mean perecntage for 28th jan - 12th feb
  prf_migration <- bind_rows(mid_baidu, pre_baidu) %>% 
    arrange(date) %>% 
    mutate(code = prf_code)
  
  # Number of trav estimates (Zhou)
  no_trav <- prf_migration %>% 
    mutate(trav_19 = as.integer(index_flow19 * scale)) %>% 
    mutate(trav_20 = as.integer(index_flow20 * scale)) %>% 
    mutate(trav_19non = as.integer(index_flow19non * scale)) %>% 
    mutate(trav_20non = as.integer(index_flow20non * scale)) %>% 
    mutate(day =  1:nrow(.)) %>% 
    select(date, day, code , trav_19, trav_20, trav_19non, trav_20non)
  
  return(no_trav)
  
}


# Function to run multiple branching processes 
bp_fun <- possibly(function(n,Rt,max_size){
  
  t0=rep(1,times=n)
  
  chain_sim(n=n, 
            infinite = max_size, 
            mu=Rt, 
            serial=function(x) {rnorm(x, mean_si, sd_si)}, 
            offspring = "nbinom", 
            size=0.54,
            t0=t0,
            tree=T)
  
},otherwise = NA_real_)

mean_si=4.7
sd_si=2.9

si <- distcrete("lnorm",
                 meanlog=log(mean_si),
                 sdlog=log(sd_si),
                 interval = 1, 
                 w = 0)

bp_rt_fun <- function(df,Reff){

  i <- incidence(df$date)
  if (i$dates[1]<as.Date("2020-01-23")){
  proj <- project(i, 
                  R = c(2.5,Reff), 
                  model="negbin", 
                  size=0.54, 
                  si = si,
                  time_change = as.numeric(as.Date("2020-01-23")-i$dates[1]),
                  n_days = 182.5, 
                  n_sim = 2)[-1,1] #remove first row (imported) and take first sim
  proj 
  }
  else{
    proj <- project(i, 
                    R = c(Reff), 
                    model="negbin", 
                    size=0.54, 
                    si = si,
                    n_days = 182.5, 
                    n_sim = 2)[-1,1]  #remove first row (imported) and take first sim
    proj
  }
    
  return(proj)

}


# Function to calculate infected arrivals
n_infected <- function(cases,pop,lambda,n){
  if(cases>=1){
    tmp <- rpois(lambda=((cases/pop)*lambda),n)
  }
  else{
    tmp <- 0
  }
  
  return(tmp)
}

summarise_proj <- function(data,cumulative) {
  if(cumulative){
    data %>% 
      cumulate() %>% 
      as.data.frame(long = T) %>%
      group_by(date) %>%
      summarise(
        inc_mean = mean(incidence),
        inc_median = quantile(probs = 0.5, incidence),
        inc_0.025 = quantile(probs = 0.025, incidence),
        inc_0.25 = quantile(probs = 0.25, incidence),
        inc_0.75 = quantile(probs = 0.75, incidence),
        inc_0.975 = quantile(probs = 0.975, incidence)
      ) %>%
      mutate(date = as.Date(date))
  }
  else{
    data %>% 
      as.data.frame(long = T) %>%
      group_by(date) %>%
      summarise(
        inc_mean = mean(incidence),
        inc_median = quantile(probs = 0.5, incidence),
        inc_0.025 = quantile(probs = 0.025, incidence),
        inc_0.25 = quantile(probs = 0.25, incidence),
        inc_0.75 = quantile(probs = 0.75, incidence),
        inc_0.975 = quantile(probs = 0.975, incidence)
      ) %>%
      mutate(date = as.Date(date))
  }
  
}

summarise_projections <- function(df,cumulative){
trav <-  df %>%
  ungroup() %>%
  select(-c(row_id,data)) %>% 
  group_by(sim,trav,after_restrictions) %>%
  nest() %>% 
  mutate(proj=future_map(.f=flatten,data)) %>% 
  mutate(add_proj=future_map(.f=merge_add_projections,proj)) %>% 
  ungroup() %>% 
  select(-c(data,proj,sim)) %>% 
  group_by(trav,after_restrictions) %>%
  nest() %>% 
  mutate(proj=future_map(.f=flatten,data)) %>% 
  mutate(merged_proj=future_map(.f=merge_projections,proj)) %>% 
  mutate(sum_proj=future_pmap(.f=summarise_proj,.l=list(merged_proj,cumulative=cumulative))) %>% 
  select(trav,after_restrictions,sum_proj) %>% 
  separate(col = trav, into = c("travel_restrictions","chunyun"),sep=", ",remove=T) %>% 
  unnest(cols=sum_proj) 

return(trav)}


summarise_imports <- function(data){
  data %>% 
  summarise(n_daily_imports_mean = mean(n_daily_imports),
          n_daily_imports_median = quantile(probs = 0.5, n_daily_imports),
          n_daily_imports_0.025 = quantile(probs = 0.025, n_daily_imports),
          n_daily_imports_0.25 = quantile(probs = 0.25, n_daily_imports),
          n_daily_imports_0.75 = quantile(probs = 0.75, n_daily_imports),
          n_daily_imports_0.975 = quantile(probs = 0.975, n_daily_imports))
}

before_after_fun <- function(data){
  ifelse(data$date[1]<as.Date("2020-01-23"),"Prior to Jan 23rd","Post Jan 23rd")
}

gh_waffle <- function(data, pal = "D", dir = -1){
  
  p <- ggplot(data, aes(x = week, y = day, fill = hours)) +
    scale_fill_viridis(name="Hours", 
                       option = pal,  # Variable color palette
                       direction = dir,  # Variable color direction
                       na.value = "grey93",
                       limits = c(0, max(data$hours))) +
    geom_tile(color = "white", size = 0.4) +
    facet_wrap("year", ncol = 1) +
    scale_x_continuous(
      expand = c(0, 0),
      breaks = seq(1, 52, length = 12),
      labels = c("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")) +
    theme_tufte(base_family = "Helvetica") +
    theme(axis.title = element_blank(),
          axis.ticks = element_blank(),
          legend.position = "bottom",
          legend.key.width = unit(1, "cm"),
          strip.text = element_text(hjust = 0.01, face = "bold", size = 12))
  
  print(p)
}