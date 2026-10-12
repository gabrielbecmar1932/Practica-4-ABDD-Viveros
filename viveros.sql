-- Ejecutar con psql:  psql -U postgres -f viveros.sql

DROP DATABASE IF EXISTS viveros;
CREATE DATABASE viveros;
\c viveros

-- Necesaria para la restricción EXCLUDE de Historico_empleado
CREATE EXTENSION IF NOT EXISTS btree_gist;


CREATE TABLE Vivero (
  id serial PRIMARY KEY,
  nombre varchar(255) NOT NULL UNIQUE,
  latitud decimal(10, 8) NOT NULL CHECK (latitud BETWEEN -90 AND 90),
  longitud decimal(11, 8) NOT NULL CHECK (longitud BETWEEN -180 AND 180),
  localidad varchar(255) NOT NULL
);

CREATE TABLE Zona (
  id_vivero INTEGER NOT NULL,
  id_zona INTEGER NOT NULL CHECK (id_zona > 0),
  tipo VARCHAR(255) NOT NULL,
  longitud decimal(11, 8) NOT NULL CHECK (longitud BETWEEN -180 AND 180),
  latitud decimal(10, 8) NOT NULL CHECK (latitud BETWEEN -90 AND 90),
  PRIMARY KEY (id_vivero, id_zona),
  FOREIGN KEY (id_vivero) REFERENCES Vivero(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE Producto (
  id serial PRIMARY KEY,
  nombre varchar(255) NOT NULL UNIQUE,
  tipo VARCHAR(255) NOT NULL CHECK (tipo IN ('planta', 'jardineria', 'decoracion')),
  precio decimal(10, 2) NOT NULL CHECK (precio > 0)
);

-- El vivero y la zona actuales de un empleado no se guardan aquí: son la
-- fila de Historico_empleado con fecha_fin a NULL.
CREATE TABLE Empleado (
  DNI varchar(9) PRIMARY KEY CHECK (DNI ~ '^[0-9]{8}[A-Z]$'),
  nombre varchar(255) NOT NULL
);

-- fidelizacion indica si pertenece al programa Tajinaste Plus; solo en ese
-- caso tiene fecha de ingreso.
CREATE TABLE Cliente (
  id serial PRIMARY KEY,
  nombre varchar(255) NOT NULL,
  fidelizacion boolean NOT NULL DEFAULT false,
  fecha_ingreso date,
  CHECK ((fidelizacion AND fecha_ingreso IS NOT NULL) OR
         (NOT fidelizacion AND fecha_ingreso IS NULL))
);

CREATE TABLE Pedido (
  id serial PRIMARY KEY,
  fecha date NOT NULL DEFAULT CURRENT_DATE,
  id_cliente INTEGER NOT NULL,
  -- Atributo derivado: suma de los subtotales de sus líneas. No se inserta
  -- a mano, lo mantiene el disparador trg_importe_pedido.
  importe decimal(10, 2) NOT NULL DEFAULT 0 CHECK (importe >= 0),
  -- Admite NULL para conservar el pedido si se borra al empleado responsable
  id_empleado varchar(9),
  FOREIGN KEY (id_cliente) REFERENCES Cliente(id) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (id_empleado) REFERENCES Empleado(DNI) ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE TABLE Zona_Producto (
  id_vivero INTEGER NOT NULL,
  id_zona INTEGER NOT NULL,
  id_producto INTEGER NOT NULL,
  cantidad INTEGER NOT NULL DEFAULT 0 CHECK (cantidad >= 0),
  PRIMARY KEY (id_vivero, id_zona, id_producto),
  FOREIGN KEY (id_vivero, id_zona) REFERENCES Zona(id_vivero, id_zona) ON DELETE CASCADE ON UPDATE CASCADE,
  FOREIGN KEY (id_producto) REFERENCES Producto(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE Pedido_producto (
  id_pedido INTEGER NOT NULL,
  id_producto INTEGER NOT NULL,
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  -- Precio al que se vendió (puede no coincidir con el precio actual)
  precio_unitario decimal(10, 2) NOT NULL CHECK (precio_unitario >= 0),
  -- Atributo derivado: lo calcula PostgreSQL, no se puede insertar a mano
  subtotal decimal(10, 2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
  PRIMARY KEY (id_pedido, id_producto),
  FOREIGN KEY (id_pedido) REFERENCES Pedido(id) ON DELETE CASCADE ON UPDATE CASCADE,
  -- Un producto que ya se ha vendido no se puede borrar
  FOREIGN KEY (id_producto) REFERENCES Producto(id) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE Historico_empleado (
  id serial PRIMARY KEY,
  -- Admite NULL: si se borra al empleado, su histórico se conserva (sigue
  -- sirviendo para la productividad de la zona) pero sin saber de quién era
  dni varchar(9),
  id_vivero INTEGER NOT NULL,
  id_zona INTEGER NOT NULL,
  fecha_inicio date NOT NULL,
  fecha_fin date,   -- NULL = destino actual
  puesto varchar(255) NOT NULL,
  productividad decimal(5, 2) NOT NULL CHECK (productividad BETWEEN 0 AND 100),
  UNIQUE (dni, fecha_inicio),
  FOREIGN KEY (dni) REFERENCES Empleado(DNI) ON DELETE SET NULL ON UPDATE CASCADE,
  FOREIGN KEY (id_vivero, id_zona) REFERENCES Zona(id_vivero, id_zona) ON DELETE CASCADE ON UPDATE CASCADE,
  CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio),
  -- Un empleado nunca tiene dos destinos a la vez: sus periodos no se solapan
  EXCLUDE USING gist (dni WITH =, daterange(fecha_inicio, fecha_fin, '[]') WITH &&)
);


-- Disparador que recalcula Pedido.importe cada vez que cambian sus líneas
CREATE FUNCTION actualizar_importe_pedido() RETURNS trigger AS $$
DECLARE
  pedido_afectado INTEGER;
BEGIN
  IF TG_OP = 'DELETE' THEN
    pedido_afectado := OLD.id_pedido;
  ELSE
    pedido_afectado := NEW.id_pedido;
  END IF;

  UPDATE Pedido
     SET importe = (SELECT COALESCE(SUM(subtotal), 0)
                      FROM Pedido_producto
                     WHERE id_pedido = pedido_afectado)
   WHERE id = pedido_afectado;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_importe_pedido
  AFTER INSERT OR UPDATE OR DELETE ON Pedido_producto
  FOR EACH ROW EXECUTE FUNCTION actualizar_importe_pedido();


-- Bonificación mensual de los clientes Tajinaste Plus según su volumen de
-- compras desde que ingresaron en el programa. Es información derivada, por
-- eso es una vista y no una tabla.
--   menos de 50 € -> 0 %     de 50 a 99,99 € -> 5 %     100 € o más -> 10 %
CREATE VIEW Bonificacion_mensual AS
SELECT c.id AS id_cliente,
       c.nombre,
       date_trunc('month', p.fecha)::date AS mes,
       SUM(p.importe) AS volumen_compras,
       CASE WHEN SUM(p.importe) >= 100 THEN 10
            WHEN SUM(p.importe) >= 50 THEN 5
            ELSE 0 END AS porcentaje
  FROM Cliente c
  JOIN Pedido p ON p.id_cliente = c.id
 WHERE c.fidelizacion AND p.fecha >= c.fecha_ingreso
 GROUP BY c.id, c.nombre, date_trunc('month', p.fecha);


-- VIVERO
INSERT INTO Vivero (nombre, localidad, latitud, longitud) VALUES
    ('Vivero Norte', 'Santa Cruz de Tenerife', 28.4636, -16.2518),
    ('Vivero Sur', 'La Laguna', 28.4852, -16.3159),
    ('Vivero Este', 'El Rosario', 28.4500, -16.2000),
    ('Vivero Oeste', 'Adeje', 28.1230, -16.7260),
    ('Vivero Central', 'La Orotava', 28.3900, -16.5230);

-- PRODUCTO
INSERT INTO Producto (nombre, tipo, precio) VALUES
    ('Ficus Benjamina', 'planta', 12.50),
    ('Cactus Redondo', 'planta', 5.99),
    ('Palmera Canaria', 'planta', 45.00),
    ('Tijeras de podar', 'jardineria', 18.99),
    ('Maceta de barro', 'decoracion', 8.50);

-- ZONA (viveros con una y con varias zonas)
INSERT INTO Zona (id_vivero, id_zona, tipo, latitud, longitud) VALUES
    (1, 1, 'exterior', 28.4640, -16.2520),
    (1, 2, 'invernadero', 28.4641, -16.2521),
    (2, 1, 'almacen', 28.4853, -16.3160),
    (3, 1, 'exterior', 28.4501, -16.2001),
    (4, 1, 'invernadero', 28.1231, -16.7261),
    (5, 1, 'exterior', 28.3901, -16.5231),
    (5, 2, 'almacen', 28.3902, -16.5232);

-- EMPLEADO (el último todavía no tiene ningún destino)
INSERT INTO Empleado (DNI, nombre) VALUES
    ('12345678A', 'Laura Martín'),
    ('23456789B', 'Pedro Suárez'),
    ('34567890C', 'Ana González'),
    ('45678901D', 'Carlos Pérez'),
    ('56789012E', 'María López'),
    ('67890123F', 'Javier Ramos');

-- CLIENTE (con y sin Tajinaste Plus)
INSERT INTO Cliente (nombre, fidelizacion, fecha_ingreso) VALUES
    ('Juan García', true, '2023-11-01'),
    ('Sofia Hernández', true, '2024-01-10'),
    ('Miguel Torres', false, NULL),
    ('Elena Díaz', true, '2024-02-01'),
    ('Roberto Fernández', false, NULL);

-- PEDIDO (el importe no se indica: lo calcula el disparador)
INSERT INTO Pedido (fecha, id_cliente, id_empleado) VALUES
    ('2024-01-15', 1, '12345678A'),
    ('2024-02-20', 2, '23456789B'),
    ('2024-03-10', 4, '34567890C'),
    ('2024-03-25', 1, '45678901D'),
    ('2024-04-05', 2, '56789012E');

-- ZONA_PRODUCTO (un producto en varias zonas, y una fila con existencias a 0)
INSERT INTO Zona_Producto (id_vivero, id_zona, id_producto, cantidad) VALUES
    (1, 1, 1, 50),
    (1, 1, 2, 30),
    (1, 2, 3, 10),
    (2, 1, 4, 25),
    (3, 1, 5, 40),
    (4, 1, 3, 0),
    (5, 1, 2, 15),
    (5, 2, 5, 20);

-- PEDIDO_PRODUCTO (el subtotal no se indica: es una columna calculada)
INSERT INTO Pedido_producto (id_pedido, id_producto, cantidad, precio_unitario) VALUES
    (1, 1, 3, 12.50),
    (1, 4, 2, 18.99),
    (2, 3, 1, 45.00),
    (3, 1, 5, 12.50),
    (3, 3, 1, 45.00),
    (4, 2, 2, 5.99),
    (5, 5, 4, 8.50),
    (5, 4, 1, 18.99);

-- HISTORICO_EMPLEADO (Laura tiene dos destinos seguidos; Carlos ya no tiene destino)
INSERT INTO Historico_empleado (dni, id_vivero, id_zona, fecha_inicio, fecha_fin, puesto, productividad) VALUES
    ('12345678A', 1, 1, '2023-01-01', '2023-06-30', 'vendedor', 87.50),
    ('12345678A', 1, 2, '2023-07-01', NULL, 'responsable', 90.00),
    ('23456789B', 2, 1, '2023-03-01', '2023-09-30', 'jardinero', 92.00),
    ('34567890C', 3, 1, '2023-06-01', NULL, 'responsable', 95.50),
    ('45678901D', 4, 1, '2023-01-01', '2024-01-01', 'vendedor', 78.00),
    ('56789012E', 1, 2, '2023-09-01', NULL, 'jardinero', 88.00);


-- Contenido de las tablas
SELECT * FROM Vivero;
SELECT * FROM Zona;
SELECT * FROM Producto;
SELECT * FROM Zona_Producto;
SELECT * FROM Empleado;
SELECT * FROM Historico_empleado;
SELECT * FROM Cliente;
SELECT * FROM Pedido;
SELECT * FROM Pedido_producto;
SELECT * FROM Bonificacion_mensual ORDER BY id_cliente, mes;


-- DELETE ejemplos

-- 1. Borrado simple de una fila
DELETE FROM Zona_Producto WHERE id_vivero = 1 AND id_zona = 1 AND id_producto = 2;

-- 2. Borrado con condición: productos sin existencias
DELETE FROM Zona_Producto WHERE cantidad = 0;

-- 3. Al borrar una línea, el disparador recalcula el importe del pedido 1
--    (pasa de 75.48 a 37.50)
DELETE FROM Pedido_producto WHERE id_pedido = 1 AND id_producto = 4;
SELECT id, importe FROM Pedido WHERE id = 1;

-- 4. CASCADE: se borran también las zonas del vivero 5 y su stock
DELETE FROM Vivero WHERE id = 5;
SELECT * FROM Zona WHERE id_vivero = 5;
SELECT * FROM Zona_Producto WHERE id_vivero = 5;

-- 5. SET NULL: al borrar a Carlos, su histórico (vivero 4, zona 1) y el
--    pedido 4, que gestionó él, se conservan pero sin empleado asociado
DELETE FROM Empleado WHERE DNI = '45678901D';
SELECT * FROM Historico_empleado WHERE id_vivero = 4;
SELECT id, id_empleado FROM Pedido WHERE id = 4;

-- 6. CASCADE: se borran los pedidos de la clienta 4 y las líneas de esos pedidos
DELETE FROM Cliente WHERE id = 4;
SELECT * FROM Pedido WHERE id_cliente = 4;
SELECT * FROM Pedido_producto WHERE id_pedido = 3;

-- 7. RESTRICT: este borrado se rechaza porque el producto 1 aparece en
--    pedidos. Está comentado para que el script se importe sin errores.
-- DELETE FROM Producto WHERE id = 1;
