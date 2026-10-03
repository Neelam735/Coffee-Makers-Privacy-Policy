<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <src:SupplierOnboardingResponse>
         <src:requestId><xsl:value-of select="$req/src:requestId"/></src:requestId>
         <src:status>DUPLICATE</src:status>
         <src:supplierId><xsl:value-of select="$CheckExistingSupplier/erp:SupplierQueryResponse/erp:items[1]/erp:SupplierId"/></src:supplierId>
         <src:supplierNumber><xsl:value-of select="$CheckExistingSupplier/erp:SupplierQueryResponse/erp:items[1]/erp:SupplierNumber"/></src:supplierNumber>
         <src:message>A supplier with this name or tax registration number already exists.</src:message>
      </src:SupplierOnboardingResponse>
   </xsl:template>
</xsl:stylesheet>
