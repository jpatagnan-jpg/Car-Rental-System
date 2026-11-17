

CREATE DATABASE car_rental_db;

USE car_rental_db;

-- 1. CUSTOMERS TABLE
CREATE TABLE customers (
    customer_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL
);

-- 2. CARS TABLE
CREATE TABLE cars (
    car_id INT AUTO_INCREMENT PRIMARY KEY,
    brand VARCHAR(50) NOT NULL,
    model VARCHAR(50) NOT NULL,
    daily_rate DECIMAL(10,2) NOT NULL,
    status ENUM('AVAILABLE', 'RENTED', 'MAINTENANCE')
        DEFAULT 'AVAILABLE',
    CHECK (daily_rate > 0)
);

-- 3. RENTALS TABLE
CREATE TABLE rentals (
    rental_id INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    car_id INT NOT NULL,
    rental_days INT NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    rental_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    status ENUM('ACTIVE', 'COMPLETED', 'CANCELLED')
        DEFAULT 'ACTIVE',

    FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),

    FOREIGN KEY (car_id)
        REFERENCES cars(car_id),

    CHECK (rental_days > 0),
    CHECK (total_amount > 0)
);

-- 4. PAYMENTS TABLE
CREATE TABLE payments (
    payment_id INT AUTO_INCREMENT PRIMARY KEY,
    rental_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    payment_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    payment_status ENUM('PAID', 'FAILED')
        DEFAULT 'PAID',

    FOREIGN KEY (rental_id)
        REFERENCES rentals(rental_id),

    CHECK (amount > 0)
);

-- 5. MAINTENANCE TABLE
CREATE TABLE maintenance (
    maintenance_id INT AUTO_INCREMENT PRIMARY KEY,
    car_id INT NOT NULL,
    description VARCHAR(255) NOT NULL,
    maintenance_date DATE NOT NULL,
    cost DECIMAL(10,2) NOT NULL,

    FOREIGN KEY (car_id)
        REFERENCES cars(car_id),

    CHECK (cost >= 0)
);


USE car_rental_db;

INSERT INTO customers
(full_name, email, phone)
VALUES
('Juan Dela Cruz', 'juan@gmail.com', '09123456789'),
('Maria Santos', 'maria@gmail.com', '09987654321'),
('Pedro Reyes', 'pedro@gmail.com', '09234567890');

INSERT INTO cars
(brand, model, daily_rate, status)
VALUES
('Toyota', 'Vios', 1500.00, 'AVAILABLE'),
('Honda', 'Civic', 2000.00, 'AVAILABLE'),
('Mitsubishi', 'Mirage', 1200.00, 'AVAILABLE'),
('Toyota', 'Fortuner', 3500.00, 'MAINTENANCE');

INSERT INTO maintenance
(car_id, description, maintenance_date, cost)
VALUES
(4, 'Regular engine maintenance', '2026-11-01', 5000.00);

USE carrental_db;
DELIMITER $$

-- Procedure 1: create a rental (transaction + rollback)
CREATE PROCEDURE sp_create_rental(
  IN p_customer_id INT,
  IN p_car_id      INT,
  IN p_start_date  DATE,
  IN p_days        INT
)
BEGIN
  DECLARE v_birth     DATE;
  DECLARE v_license   DATE;
  DECLARE v_due       DATE;
  DECLARE v_car_state VARCHAR(20);
  DECLARE v_rate      DECIMAL(10,2);
  DECLARE v_base      DECIMAL(10,2);
  DECLARE v_discount  DECIMAL(10,2);
  DECLARE v_rental_id INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  -- Rule: rental length 1 to 30 days
  IF p_days IS NULL OR p_days < 1 OR p_days > 30 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental days must be between 1 and 30';
  END IF;

  -- Rule: start date cannot be in the past
  IF p_start_date IS NULL OR p_start_date < CURDATE() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Start date cannot be in the past';
  END IF;

  SET v_due = DATE_ADD(p_start_date, INTERVAL p_days DAY);

  -- Rule: customer must be 21+ with a license valid until the rental ends
  SELECT birth_date, license_expiry INTO v_birth, v_license
    FROM customers WHERE customer_id = p_customer_id;
  IF v_birth IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found';
  END IF;
  IF TIMESTAMPDIFF(YEAR, v_birth, CURDATE()) < 21 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer must be at least 21 years old';
  END IF;
  IF v_license < v_due THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Driver license expires before the rental ends';
  END IF;

  -- Rule: car must exist and not be in maintenance (uses function)
  SET v_car_state = fn_get_car_status(p_car_id);
  IF v_car_state = 'NOT_FOUND' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Car not found';
  ELSEIF v_car_state = 'MAINTENANCE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Car is under maintenance';
  END IF;

  START TRANSACTION;

  -- Lock the car row, then re-check inside the transaction
  SELECT c.status, cc.daily_rate INTO v_car_state, v_rate
    FROM cars c JOIN car_categories cc ON cc.category_id = c.category_id
   WHERE c.car_id = p_car_id FOR UPDATE;

  IF v_car_state <> 'AVAILABLE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Car is currently rented';
  END IF;

  -- Rule: long-rental discount via function
  SET v_base     = v_rate * p_days;
  SET v_discount = v_base * fn_get_discount_rate(p_days);

  INSERT INTO rentals (customer_id, car_id, start_date, due_date, days, base_cost, discount, total_cost)
  VALUES (p_customer_id, p_car_id, p_start_date, v_due, p_days, v_base, v_discount, v_base - v_discount);
  SET v_rental_id = LAST_INSERT_ID();

  UPDATE cars SET status = 'RENTED' WHERE car_id = p_car_id;

  COMMIT;

  SELECT v_rental_id AS rental_id, p_start_date AS start_date, v_due AS due_date,
         v_base AS base_cost, v_discount AS discount, v_base - v_discount AS total_cost;
END$$

-- Procedure 2: return a car, compute late fee, record payment
CREATE PROCEDURE sp_return_car(
  IN p_rental_id   INT,
  IN p_return_date DATE
)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_car_id INT;
  DECLARE v_start  DATE;
  DECLARE v_total  DECIMAL(10,2);
  DECLARE v_late   DECIMAL(10,2);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_return_date IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date is required';
  END IF;

  START TRANSACTION;

  SELECT status, car_id, start_date, total_cost INTO v_status, v_car_id, v_start, v_total
    FROM rentals WHERE rental_id = p_rental_id FOR UPDATE;

  IF v_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental not found';
  ELSEIF v_status <> 'ACTIVE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental is not active (already returned or cancelled)';
  END IF;

  IF p_return_date < v_start THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date cannot be before the start date';
  END IF;

  -- Rule: late fee via function
  SET v_late = fn_calculate_late_fee(p_rental_id, p_return_date);

  UPDATE rentals
     SET return_date = p_return_date, late_fee = v_late, status = 'RETURNED'
   WHERE rental_id = p_rental_id;

  UPDATE cars SET status = 'AVAILABLE' WHERE car_id = v_car_id;

  INSERT INTO payments (rental_id, amount) VALUES (p_rental_id, v_total + v_late);

  COMMIT;

  SELECT p_rental_id AS rental_id, p_return_date AS return_date,
         v_total AS rental_cost, v_late AS late_fee, v_total + v_late AS amount_paid;
END$$

-- Procedure 3: cancel an active rental and free the car
CREATE PROCEDURE sp_cancel_rental(IN p_rental_id INT)
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_car_id INT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT status, car_id INTO v_status, v_car_id
    FROM rentals WHERE rental_id = p_rental_id FOR UPDATE;

  IF v_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental not found';
  ELSEIF v_status <> 'ACTIVE' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only active rentals can be cancelled';
  END IF;

  UPDATE rentals SET status = 'CANCELLED' WHERE rental_id = p_rental_id;
  UPDATE cars SET status = 'AVAILABLE' WHERE car_id = v_car_id;

  COMMIT;

  SELECT rental_id, status FROM rentals WHERE rental_id = p_rental_id;
END$$

DELIMITER ;