-- phpMyAdmin SQL Dump
-- version 5.2.3
-- https://www.phpmyadmin.net/
--
-- Host: localhost
-- Generation Time: Jan 05, 2026 at 01:13 AM
-- Server version: 11.8.3-MariaDB-0+deb13u1 from Debian
-- PHP Version: 8.5.0

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `foxhound_db1`
--

-- --------------------------------------------------------

--
-- Table structure for table `player_stats`
--

CREATE TABLE `player_stats` (
  `id` int(10) UNSIGNED NOT NULL,
  `steamid` varchar(32) NOT NULL,
  `player_name` varchar(128) NOT NULL DEFAULT '',
  `total_kills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_headshots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_shots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_kills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_headshots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_shots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_points_start` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_points_current` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_kills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_headshots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_shots` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_points_start` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_points_current` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `last_daily_reset` date DEFAULT NULL,
  `last_weekly_reset` date DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `player_stats`
--
ALTER TABLE `player_stats`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `idx_steamid` (`steamid`),
  ADD KEY `idx_daily_score` (`daily_kills`,`daily_headshots`),
  ADD KEY `idx_weekly_score` (`weekly_kills`,`weekly_headshots`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `player_stats`
--
ALTER TABLE `player_stats`
  MODIFY `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=13;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
