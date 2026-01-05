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
-- Table structure for table `medic_stats`
--

CREATE TABLE `medic_stats` (
  `id` int(10) UNSIGNED NOT NULL,
  `steamid` varchar(32) NOT NULL,
  `player_name` varchar(128) NOT NULL DEFAULT '',
  `total_heals` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_revives` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_defibs` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_pills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `total_assists` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_heals` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_revives` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_defibs` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_pills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `daily_assists` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_heals` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_revives` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_defibs` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_pills` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `weekly_assists` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `last_daily_reset` date DEFAULT NULL,
  `last_weekly_reset` date DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `medic_stats`
--
ALTER TABLE `medic_stats`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `idx_steamid` (`steamid`),
  ADD KEY `idx_daily_score` (`daily_heals`,`daily_revives`,`daily_defibs`),
  ADD KEY `idx_weekly_score` (`weekly_heals`,`weekly_revives`,`weekly_defibs`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `medic_stats`
--
ALTER TABLE `medic_stats`
  MODIFY `id` int(10) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=106;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
